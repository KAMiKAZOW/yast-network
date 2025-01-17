# Copyright (c) [2019] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "y2network/connection_config/ip_config"
require "y2network/ip_address"
require "y2network/boot_protocol"
require "y2network/startmode"

Yast.import "Host"

module Y2Network
  module Sysconfig
    module ConnectionConfigReaders
      # This is the base class for connection config readers.
      #
      # The derived classes should implement {#update_connection_config} method.
      # methods.
      class Base
        # @return [Y2Network::Sysconfig::InterfaceFile] Interface's configuration file
        attr_reader :file

        # Constructor
        #
        # @param file [Y2Network::Sysconfig::InterfaceFile] Interface's configuration file
        def initialize(file)
          @file = file
        end

        # Builds a connection configuration object
        #
        # @return [Y2Network::ConnectionConfig::Base]
        def connection_config
          connection_class.new.tap do |conn|
            conn.bootproto = BootProtocol.from_name(file.bootproto || "static")
            conn.description = file.name
            conn.interface = file.interface
            conn.ip = all_ips.find { |i| i.id.empty? }
            conn.ip_aliases = all_ips.reject { |i| i.id.empty? }
            conn.name = file.interface
            conn.lladdress = file.lladdr
            conn.startmode = Startmode.create(file.startmode || "manual")
            conn.startmode.priority = file.ifplugd_priority if conn.startmode.name == "ifplugd"
            conn.ethtool_options = file.ethtool_options
            conn.firewall_zone = file.zone
            conn.hostname = hostname(conn)
            update_connection_config(conn)
          end
        end

      private

        # Returns the class of the connection configuration
        #
        # @return [Class]
        def connection_class
          class_name = self.class.to_s.split("::").last
          file_name = class_name.gsub(/(\w)([A-Z])/, "\\1_\\2").downcase
          require "y2network/connection_config/#{file_name}"
          Y2Network::ConnectionConfig.const_get(class_name)
        end

        # Sets connection config settings from the given file
        #
        # @note This method should be redefined by derived classes.
        #
        # @param _conn [Y2Network::ConnectionConfig::Base]
        def update_connection_config(_conn); end

        # Returns the IPs configuration from the file
        #
        # @return [Array<Y2Network::ConnectionConfig::IPAdress>] IP addresses configuration
        # @see Y2Network::ConnectionConfig::IPConfig
        def all_ips
          @all_ips ||= file.ipaddrs.each_with_object([]) do |(id, ip), all|
            next unless ip.is_a?(Y2Network::IPAddress)

            ip_address = build_ip(ip, file.prefixlens[id], file.netmasks[id])
            all << Y2Network::ConnectionConfig::IPConfig.new(
              ip_address,
              id:             id,
              label:          file.labels[id],
              remote_address: file.remote_ipaddrs[id],
              broadcast:      file.broadcasts[id]
            )
          end
        end

        # Builds an IP address
        #
        # It takes an IP address and, optionally, a prefix or a netmask.
        #
        # @param ip      [Y2Network::IPAddress] IP address
        # @param prefix  [Integer,nil] Address prefix
        # @param netmask [String,nil] Netmask
        def build_ip(ip, prefix, netmask)
          ipaddr = ip.clone
          return ipaddr if ip.prefix?

          ipaddr.netmask = netmask if netmask
          ipaddr.prefix = prefix if prefix
          ipaddr
        end

        # Returns the hostname for the given connection
        #
        # @return [String,nil]
        def hostname(conn)
          return nil unless conn.ip

          Yast::Host.Read
          Yast::Host.names(conn.ip.address.address.to_s).first
        end
      end
    end
  end
end
