require 'log4r'

require 'vagrant/util/platform'

require File.expand_path("../base", __FILE__)

module VagrantPlugins
  module Parallels
    module Driver
      # Driver for Parallels Desktop 9.
      class PD_9 < Base
        def initialize(uuid)
          super()

          @logger = Log4r::Logger.new("vagrant::provider::parallels::pd_9")
          @uuid = uuid
        end


        def compact(uuid)
          used_drives = read_settings.fetch('Hardware', {}).select { |name, _| name.start_with? 'hdd' }
          used_drives.each_value do |drive_params|
            execute(:prl_disk_tool, 'compact', '--hdd', drive_params["image"]) do |type, data|
              lines = data.split("\r")
              # The progress of the compact will be in the last line. Do a greedy
              # regular expression to find what we're looking for.
              if lines.last =~ /.+?(\d{,3}) ?%/
                yield $1.to_i if block_given?
              end
            end
          end
        end

        def clear_shared_folders
          shf = read_settings.fetch("Host Shared Folders", {}).keys
          shf.delete("enabled")
          shf.each do |folder|
            execute("set", @uuid, "--shf-host-del", folder)
          end
        end

        def create_host_only_network(options)
          # Create the interface
          execute(:prlsrvctl, "net", "add", options[:name], "--type", "host-only")

          # Configure it
          args = ["--ip", "#{options[:adapter_ip]}/#{options[:netmask]}"]
          if options[:dhcp]
            args.concat(["--dhcp-ip", options[:dhcp][:ip],
                         "--ip-scope-start", options[:dhcp][:lower],
                         "--ip-scope-end", options[:dhcp][:upper]])
          end

          execute(:prlsrvctl, "net", "set", options[:name], *args)

          # Determine interface to which it has been bound
          net_info = json { execute(:prlsrvctl, 'net', 'info', options[:name], '--json', retryable: true) }
          bound_to = net_info['Bound To']

          # Return the details
          return {
            :name => options[:name],
            :bound_to => bound_to,
            :ip   => options[:adapter_ip],
            :netmask => options[:netmask],
            :dhcp => options[:dhcp]
          }
        end

        def delete
          execute('delete', @uuid)
        end

        def delete_disabled_adapters
          read_settings.fetch('Hardware', {}).each do |adapter, params|
            if adapter.start_with?('net') and !params.fetch("enabled", true)
              execute('set', @uuid, '--device-del', adapter)
            end
          end
        end

        def delete_unused_host_only_networks
          networks = read_virtual_networks

          # 'Shared'(vnic0) and 'Host-Only'(vnic1) are default in Parallels Desktop
          # They should not be deleted anyway.
          networks.keep_if do |net|
            net['Type'] == "host-only" &&
              net['Bound To'].match(/^(?>vnic|Parallels Host-Only #)(\d+)$/)[1].to_i >= 2
          end

          read_vms_info.each do |vm|
            used_nets = vm.fetch('Hardware', {}).select { |name, _| name.start_with? 'net' }
            used_nets.each_value do |net_params|
              networks.delete_if { |net|  net['Bound To'] == net_params.fetch('iface', nil) }
            end

          end

          networks.each do |net|
            # Delete the actual host only network interface.
            execute(:prlsrvctl, "net", "del", net["Network ID"])
          end
        end

        def enable_adapters(adapters)
          # Get adapters which have already configured for this VM
          # Such adapters will be just overridden
          existing_adapters = read_settings.fetch('Hardware', {}).keys.select { |name| name.start_with? 'net' }

          # Disable all previously existing adapters (except shared 'vnet0')
          existing_adapters.each do |adapter|
            if adapter != 'vnet0'
              execute('set', @uuid, '--device-set', adapter, '--disable')
            end
          end

          adapters.each do |adapter|
            args = []
            if existing_adapters.include? "net#{adapter[:adapter]}"
              args.concat(["--device-set","net#{adapter[:adapter]}", "--enable"])
            else
              args.concat(["--device-add", "net"])
            end

            if adapter[:hostonly] or adapter[:bridge]
              # Oddly enough, but there is a 'bridge' anyway.
              # The only difference is the destination interface:
              # - in host-only (private) network it will be bridged to the 'vnicX' device
              # - in real bridge (public) network it will be bridged to the assigned device
              args.concat(["--type", "bridged", "--iface", adapter[:bound_to]])
            end

            if adapter[:shared]
              args.concat(["--type", "shared"])
            end

            if adapter[:mac_address]
              args.concat(["--mac", adapter[:mac_address]])
            end

            if adapter[:nic_type]
              args.concat(["--adapter-type", adapter[:nic_type].to_s])
            end

            execute("set", @uuid, *args)
          end
        end

        def execute_command(command)
          execute(*command)
        end

        def export(path, tpl_name)
          execute("clone", @uuid, "--name", tpl_name, "--template", "--dst", path.to_s) do |type, data|
            lines = data.split("\r")
            # The progress of the export will be in the last line. Do a greedy
            # regular expression to find what we're looking for.
            if lines.last =~ /.+?(\d{,3}) ?%/
              yield $1.to_i if block_given?
            end
          end
          read_vms[tpl_name]
        end

        def halt(force=false)
          args = ['stop', @uuid]
          args << '--kill' if force
          execute(*args)
        end

        def import(template_uuid)
          template_name = read_vms.key(template_uuid)
          vm_name = "#{template_name}_#{(Time.now.to_f * 1000.0).to_i}_#{rand(100000)}"

          execute("clone", template_uuid, '--name', vm_name) do |type, data|
            lines = data.split("\r")
            # The progress of the import will be in the last line. Do a greedy
            # regular expression to find what we're looking for.
            if lines.last =~ /.+?(\d{,3}) ?%/
              yield $1.to_i if block_given?
            end
          end
          read_vms[vm_name]
        end

        def read_bridged_interfaces
          net_list = read_virtual_networks

          # Skip 'vnicXXX' and 'Default' interfaces
          net_list.delete_if do |net|
            net['Type'] != "bridged" or
              net['Bound To'] =~ /^(vnic(.+?))$/ or
              net['Network ID'] == "Default"
          end

          bridged_ifaces = []
          net_list.collect do |iface|
            info = {}
            ifconfig = execute(:ifconfig, iface['Bound To'])
            # Assign default values
            info[:name]    = iface['Network ID'].gsub(/\s\(.*?\)$/, '')
            info[:bound_to] = iface['Bound To']
            info[:ip]      = "0.0.0.0"
            info[:netmask] = "0.0.0.0"
            info[:status]  = "Down"

            if ifconfig =~ /(?<=inet\s)(\S*)/
              info[:ip] = $1.to_s
            end
            if ifconfig =~ /(?<=netmask\s)(\S*)/
              # Netmask will be converted from hex to dec:
              # '0xffffff00' -> '255.255.255.0'
              info[:netmask] = $1.hex.to_s(16).scan(/../).each.map{|octet| octet.hex}.join(".")
            end
            if ifconfig =~ /\W(UP)\W/ and ifconfig !~ /(?<=status:\s)inactive$/
              info[:status] = "Up"
            end

            bridged_ifaces << info
          end
          bridged_ifaces
        end

        def read_guest_tools_version
          read_settings.fetch('GuestTools', {}).fetch('version', nil)
        end

        def read_host_only_interfaces
          net_list = read_virtual_networks
          net_list.keep_if { |net| net['Type'] == "host-only" }

          hostonly_ifaces = []
          net_list.collect do |iface|
            info = {}
            net_info = json { execute(:prlsrvctl, 'net', 'info', iface['Network ID'], '--json') }
            # Really we need to work with bounded virtual interface
            info[:name]     = net_info['Network ID']
            info[:bound_to] = net_info['Bound To']
            info[:ip]       = net_info['Parallels adapter']['IP address']
            info[:netmask]  = net_info['Parallels adapter']['Subnet mask']
            # Such interfaces are always in 'Up'
            info[:status]   = "Up"

            # There may be a fake DHCPv4 parameters
            # We can trust them only if adapter IP and DHCP IP are in the same subnet
            dhcp_ip = net_info['DHCPv4 server']['Server address']
            if network_address(info[:ip], info[:netmask]) == network_address(dhcp_ip, info[:netmask])
              info[:dhcp] = {
                :ip      => dhcp_ip,
                :lower   => net_info['DHCPv4 server']['IP scope start address'],
                :upper   => net_info['DHCPv4 server']['IP scope end address']
              }
            end
            hostonly_ifaces << info
          end
          hostonly_ifaces
        end

        def read_ip_dhcp
          mac_addr = read_mac_address.downcase
          File.foreach("/Library/Preferences/Parallels/parallels_dhcp_leases") do |line|
            if line.include? mac_addr
              ip = line[/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/]
              return ip
            end
          end
        end

        def read_mac_address
          read_settings.fetch('Hardware', {}).fetch('net0', {}).fetch('mac', nil)
        end

        def read_network_interfaces
          nics = {}

          # Get enabled VM's network interfaces
          ifaces = read_settings.fetch('Hardware', {}).keep_if do |dev, params|
            dev.start_with?('net') and params.fetch("enabled", true)
          end
          ifaces.each do |name, params|
            adapter = name.match(/^net(\d+)$/)[1].to_i
            nics[adapter] ||= {}

            if params['type'] == "shared"
              nics[adapter][:type] = :shared
            elsif params['type'] == "host"
              # It is PD internal host-only network and it is bounded to 'vnic1'
              nics[adapter][:type] = :hostonly
              nics[adapter][:hostonly] = "vnic1"
            elsif params['type'] == "bridged" and params.fetch('iface','').start_with?('vnic')
              # Bridged to the 'vnicXX'? Then it is a host-only, actually.
              nics[adapter][:type] = :hostonly
              nics[adapter][:hostonly] = params.fetch('iface','')
            elsif params['type'] == "bridged"
              nics[adapter][:type] = :bridged
              nics[adapter][:bridge] = params.fetch('iface','')
            end
          end
          nics
        end

        def read_settings
          vm = json { execute('list', @uuid, '--info', '--json', retryable: true) }
          vm.last
        end

        def read_state
          vm = json { execute('list', @uuid, '--json', retryable: true) }
          return nil if !vm.last
          vm.last.fetch('status').to_sym
        end

        def read_virtual_networks
          json { execute(:prlsrvctl, 'net', 'list', '--json', retryable: true) }
        end

        def read_vms
          results = {}
          vms_arr = json([]) do
            execute('list', '--all', '--json', retryable: true)
          end
          templates_arr = json([]) do
            execute('list', '--all', '--json', '--template', retryable: true)
          end
          vms = vms_arr | templates_arr
          vms.each do |item|
            results[item.fetch('name')] = item.fetch('uuid')
          end

          results
        end

        # Parse the JSON from *all* VMs and templates. Then return an array of objects (without duplicates)
        def read_vms_info
          vms_arr = json([]) do
            execute('list', '--all','--info', '--json', retryable: true)
          end
          templates_arr = json([]) do
            execute('list', '--all','--info', '--json', '--template', retryable: true)
          end
          vms_arr | templates_arr
        end

        def read_vms_paths
          list = {}
          read_vms_info.each do |item|
            if Dir.exists? item.fetch('Home')
              list[File.realpath item.fetch('Home')] = item.fetch('ID')
            end
          end

          list
        end

        def register(pvm_file)
          execute("register", pvm_file)
        end

        def registered?(uuid)
          read_vms.has_value?(uuid)
        end

        def resume
          execute('resume', @uuid)
        end

        def set_mac_address(mac)
          execute('set', @uuid, '--device-set', 'net0', '--type', 'shared', '--mac', mac)
        end

        def set_name(name)
          execute('set', @uuid, '--name', name, :retryable => true)
        end

        def share_folders(folders)
          folders.each do |folder|
            # Add the shared folder
            execute('set', @uuid, '--shf-host-add', folder[:name], '--path', folder[:hostpath])
          end
        end

        def ssh_port(expected_port)
          expected_port
        end

        def start
          execute('start', @uuid)
        end

        def suspend
          execute('suspend', @uuid)
        end

        def unregister(uuid)
          execute("unregister", uuid)
        end

        def verify!
          version
        end

        def version
          if execute('--version', retryable: true) =~ /prlctl version ([\d\.]+)/
            $1.downcase
          else
            raise VagrantPlugins::Parallels::Errors::ParallelsInstallIncomplete
          end
        end

        def vm_exists?(uuid)
          raw("list", uuid).exit_code == 0
        end
      end
    end
  end
end
