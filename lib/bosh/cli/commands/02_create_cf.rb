require "yaml"
require "bosh/cloudfoundry"

module Bosh::Cli::Command
  class CloudFoundry < Base
    include FileUtils
    include Bosh::Cli::Validation
    include Bosh::Cloudfoundry

    usage "create cf"
    desc "create a deployment file for Cloud Foundry and deploy it"
    option "--dns mycloud.com", "Primary domain"
    option "--ip 1.2.3.4,1.2.3.5", Array, "Public IPs; one per router node"
    option "--name cf-<timestamp>", "Unique bosh deployment name"
    option "--disk 4096", Integer, "Size of persistent disk (Mb)"
    option "--security-group default", String, "Security group to assign to provisioned VMs"
    option "--deployment-size medium", String, "Size of deployment - medium or large"
    def create_cf
      auth_required
      bosh_status # preload

      setup_deployment_attributes

      ip_addresses = options[:ip]
      err("USAGE: bosh create cf --ip 1.2.3.4 -- please provide one IP address that will be bound to router.") if ip_addresses.blank?
      err("Only one IP address is supported currently. Please create an issue to mention you need more.") if ip_addresses.size > 1
      attrs.set(:ip_addresses, ip_addresses)

      attrs.set_unless_nil(:name, options[:name])
      attrs.set_unless_nil(:dns, options[:dns])
      attrs.set_unless_nil(:persistent_disk, options[:disk])
      attrs.set_unless_nil(:security_group, options[:security_group])
      attrs.set_unless_nil(:common_password, options[:common_password])
      attrs.set_unless_nil(:deployment_size, options[:deployment_size])

      release_version = ReleaseVersion.latest_version_number
      @release_version_cpi_size = 
        ReleaseVersionCpiSize.new(@release_version_cpi, attrs.deployment_size)

      nl
      say "CPI: #{bosh_cpi.make_green}"
      say "DNS mapping: #{attrs.validated_color(:dns)} --> #{attrs.validated_color(:ip_addresses)}"
      say "Deployment name: #{attrs.validated_color(:name)}"
      say "Deployment size: #{attrs.validated_color(:deployment_size)}"
      say "Persistent disk: #{attrs.validated_color(:persistent_disk)}"
      say "Security group: #{attrs.validated_color(:security_group)}"
      nl

      validate_deployment_attributes

      unless confirmed?("Security group #{attrs.validated_color(:security_group)} exists with ports #{attrs.required_ports.join(", ")}")
        cancel_deployment
      end
      unless confirmed?("Creating Cloud Foundry")
        cancel_deployment
      end

      raise Bosh::Cli::ValidationHalted unless errors.empty?

      @deployment_file = DeploymentFile.new(@release_version_cpi_size, attrs, bosh_status)
      perform_deploy(options)
    rescue Bosh::Cli::ValidationHalted
      errors.each do |error|
        say error.make_red
      end
      exit 1
    end

    usage "show cf attributes"
    desc "display the deployment attributes, indicate which are changable"
    def show_cf_attributes
      setup_deployment_attributes
      reconstruct_deployment_file
      nl
      say "Immutable attributes:"
      attrs.immutable_attributes.each do |attr_name|
        say "#{attr_name}: #{attrs.validated_color(attr_name.to_sym)}"
      end
      nl
      say "Mutable (changable) attributes:"
      attrs.mutable_attributes.each do |attr_name|
        say "#{attr_name}: #{attrs.validated_color(attr_name.to_sym)}"
      end
    end

    usage "change cf attributes"
    desc "change deployment attributes and perform bosh deploy"
    def change_cf_attributes(*attribute_values)
      setup_deployment_attributes
      reconstruct_deployment_file

      # TODO fail if setting immutable attributes
      attribute_values.each do |attr_value|
        # FIXME check that correct format of input: xyz=123 and give feedback
        attr_name, value = attr_value.split(/=/)
        previous_value = attrs.validated_color(attr_name)
        step("Checking '#{attr_name}' is a valid mutable attribute",
             "Attribute '#{attr_name}' is not a valid mutable attribute (see 'bosh show cf attributes')", :non_fatal) do
          attrs.mutable_attribute?(attr_name)
        end
        attrs.set_mutable(attr_name, value)
      end

      validate_deployment_attributes
      # TODO show validated attributes like "create cf"

      raise Bosh::Cli::ValidationHalted unless errors.empty?

      perform_deploy(options)

    rescue Bosh::Cli::ValidationHalted
      errors.each do |error|
        say error.make_red
      end
      exit 1
    end

    protected
    def setup_deployment_attributes
      @release_version_cpi = ReleaseVersionCpi.latest_for_cpi(bosh_cpi)
      @deployment_attributes = DeploymentAttributes.new(director, bosh_status, @release_version_cpi)
    end

    def attrs
      @deployment_attributes
    end

    # After a deployment is created, the input properties/attributes are stored within the generated
    # deployment file. Therefore, to update a deployment, first we must load in the attributes.
    def reconstruct_deployment_file
      @deployment_file = DeploymentFile.reconstruct_from_deployment_file(deployment, director, bosh_status)
      @deployment_attributes = @deployment_file.deployment_attributes
      @release_version_cpi_size = @deployment_file.release_version_cpi_size
    end

    def perform_deploy(deploy_options={})
      @deployment_file.perform(deploy_options)
    end

    def bosh_status
      @bosh_status ||= begin
        step("Fetching bosh information", "Cannot fetch bosh information", :fatal) do
           @bosh_status = director.get_status
        end
        @bosh_status
      end
    end

    def bosh_cpi
      bosh_status["cpi"]
    end

    def validate_deployment_attributes
      attrs.validate_deployment_size
      attrs.validate_dns_mapping
    end

  end
end
