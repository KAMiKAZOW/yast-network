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

require "ui/text_helpers"
require "yast"
require "cwm/custom_widget"
require "y2network/widgets/slave_items"

Yast.import "Label"
Yast.import "Lan"
Yast.import "Popup"
Yast.import "UI"

module Y2Network
  module Widgets
    class BondSlave < CWM::CustomWidget
      include SlaveItems
      include ::UI::TextHelpers

      def initialize(settings)
        textdomain "network"
        @settings = settings
      end

      def contents
        Frame(
          _("Bond Slaves and Order"),
          VBox(
            MultiSelectionBox(Id(:bond_slaves_items), Opt(:notify), "", []),
            HBox(
              PushButton(Id(:bond_slaves_up), Opt(:disabled), _("Up")),
              PushButton(Id(:bond_slaves_down), Opt(:disabled), _("Down"))
            )
          )
        )
      end

      def handle(event)
        if event["EventReason"] == "SelectionChanged"
          enable_slave_buttons
        elsif event["EventReason"] == "Activated" && event["WidgetClass"] == :PushButton
          items = ui_items || []
          current = value.to_s
          index = value_index
          case event["ID"]
          when :up
            items[index], items[index - 1] = items[index - 1], items[index]
          when :down
            items[index], items[index + 1] = items[index + 1], items[index]
          else
            log.warn("unknown action #{event["ID"]}")
            return nil
          end
          Yast::UI.ChangeWidget(:bond_slaves_items, :Items, items)
          Yast::UI.ChangeWidget(:bond_slaves_items, :CurrentItem, current)
          enable_slave_buttons
        else
          log.debug("event:#{event}")
        end

        nil
      end

      def help
        # TODO: write it
        _(
          "<p>Select the slave devices for the bond device.\n" \
            "Only devices with the device activation set to <b>Never</b> " \
            "and with <b>No Address Setup</b> are available.</p>"
        )
      end

      # Default function to init the value of slave devices box for bonding.
      def init
        slaves = @settings.slaves
        # TODO: use def items, but problem now is that slave_items returns term and not array
        items = slave_items_from(
          @settings.bondable_interfaces.map(&:name),
          slaves,
          Yast::Lan.yast_config # ideally get it from builder?
        )

        # reorder the items
        l1, l2 = items.partition { |t| slaves.include? t[0][0] }

        items = l1 + l2.sort_by { |t| justify_dev_name(t[0][0]) }

        Yast::UI.ChangeWidget(:bond_slaves_items, :Items, items)

        Yast::UI.ChangeWidget(
          :bond_slaves_items,
          :SelectedItems,
          slaves
        )

        enable_slave_buttons

        nil
      end

      # Default function to store the value of slave devices box.
      def store
        @settings.slaves = selected_items
      end

      # Validates created bonding. Currently just prevent the user to create a
      # bond with more than one interface sharing the same physical port id
      #
      # @return true if valid or user decision if not
      def validate
        physical_ports = repeated_physical_port_ids(selected_items)

        if !physical_ports.empty?
          return false unless continue_with_duplicates?(physical_ports)
        end

        if @settings.already_configured?(selected_items || [])
          return Yast::Popup.ContinueCancel(
            _(
              "At least one selected device is already configured.\n" \
                "Adapt the configuration for bonding?\n"
            )
          )
        else
          true
        end
      end

      def value
        # TODO: it is multiselection, so does it make sense?
        Yast::UI.QueryWidget(:bond_slaves_items, :CurrentItem)
      end

      def selected_items
        Yast::UI.QueryWidget(:bond_slaves_items, :SelectedItems) || []
      end

      def ui_items
        Yast::UI.QueryWidget(:bond_slaves_items, :Items) || []
      end

      def value_index
        ui_items.index { |i| i[0] == Id(value) }
      end

      def enable_slave_buttons
        if value_index
          Yast::UI.ChangeWidget(:bond_slaves_up, :Enabled, value_index > 0)
          Yast::UI.ChangeWidget(:bond_slaves_down, :Enabled, value_index < ui_items.size - 1)
        else
          Yast::UI.ChangeWidget(:bond_slaves_up, :Enabled, false)
          Yast::UI.ChangeWidget(:bond_slaves_down, :Enabled, false)
        end
      end

      # A helper for sort devices by name. It justify at right with 0's numeric parts of given
      # device name until 5 digits.
      #
      # TODO: should not be in CWM
      # ==== Examples
      #
      #   justify_dev_name("eth0") # => "eth00000"
      #   justify_dev_name("eth111") # => "eth00111"
      #   justify_dev_name("enp0s25") # => "enp00000s00025"
      #
      # @param name [String] device name
      # @return [String] given name with numbers justified at right
      def justify_dev_name(name)
        splited_dev_name = name.scan(/\p{Alpha}+|\p{Digit}+/)
        splited_dev_name.map! do |d|
          if d =~ /\p{Digit}+/
            d.rjust(5, "0")
          else
            d
          end
        end.join
      end

      # Given a list of device names returns a hash of physical port ids mapping
      # device names if at least two devices shared the same physical port id
      # TODO: backend method
      #
      # @param slaves [Array<String>] bonding slaves
      # @return [Hash{String => Array<String>}] of duplicated physical port ids
      def repeated_physical_port_ids(slaves)
        physical_port_ids = {}

        slaves.each do |slave|
          if physical_port_id?(slave)
            p = physical_port_ids[physical_port_id(slave)] ||= []
            p << slave
          end
        end

        physical_port_ids.select! { |_k, v| v.size > 1 }

        physical_port_ids
      end

      # Given a map of duplicated port ids with device names, aks the user if he
      # would like to continue or not.
      #
      # @param physical_ports [Hash{String => Array<String>}] hash of duplicated physical port ids
      # mapping to an array of device names
      # @return [Boolean] true if continue with duplicates, otherwise false
      def continue_with_duplicates?(physical_ports)
        message = physical_ports.map do |port, slave|
          label = "PhysicalPortID (#{port}): "
          wrap_text(slave.join(", "), 76, prepend_text: label)
        end.join("\n")

        Yast::Popup.YesNoHeadline(
          Yast::Label.WarningMsg,
          # Translators: Warn the user about not desired effect
          _("The interfaces selected share the same physical port and bonding " \
            "them \nmay not have the desired effect of redundancy.\n\n%s\n\n" \
            "Really continue?\n") % message
        )
      end
    end
  end
end
