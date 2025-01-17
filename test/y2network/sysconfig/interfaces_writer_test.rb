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

require_relative "../../test_helper"
require "y2network/sysconfig/interfaces_writer"
require "y2network/udev_rule"
require "y2network/physical_interface"
require "y2network/interfaces_collection"
require "tmpdir"

describe Y2Network::Sysconfig::InterfacesWriter do
  subject(:writer) { described_class.new }

  describe "#write" do
    let(:interfaces) { Y2Network::InterfacesCollection.new([eth0]) }
    let(:eth0) do
      Y2Network::PhysicalInterface.new("eth0", hardware: hardware).tap do |i|
        i.renaming_mechanism = renaming_mechanism
        i.custom_driver = driver
      end
    end

    let(:hardware) do
      instance_double(
        Y2Network::Hwinfo, name: "Ethernet Card 0", busid: "00:1c.0", mac: "01:23:45:67:89:ab",
        dev_port: "1", modalias: "virtio:d00000001v00001AF4"
      )
    end
    let(:renaming_mechanism) { :none }
    let(:driver) { nil }
    let(:scr_root) { Dir.mktmpdir }

    before do
      allow(Yast::Execute).to receive(:on_target)
      allow(writer).to receive(:sleep)

      # prevent collision with real hardware
      allow(Y2Network::UdevRule).to receive(:naming_rules).and_return([])
      allow(Y2Network::UdevRule).to receive(:drivers_rules).and_return([])
    end

    around do |example|

      FileUtils.cp_r(File.join(DATA_PATH, "scr_read", "etc"), scr_root)
      change_scr_root(scr_root, &example)
    ensure
      FileUtils.remove_entry(scr_root)

    end

    context "when the interface is renamed" do
      before do
        eth0.rename("eth1", renaming_mechanism)
      end

      it "sets the interface down" do
        expect(Yast::Execute).to receive(:on_target).with("/sbin/ifdown", "eth0")
        subject.write(interfaces)
      end

      context "during autoinstallation" do
        before do
          allow(Yast::Mode).to receive(:autoinst).and_return(true)
        end

        it "does not set the interface down" do
          expect(Yast::Execute).to_not receive(:on_target).with("/sbin/ifdown", any_args)
          subject.write(interfaces)
        end
      end

      context "when the interface is renamed using the MAC" do
        let(:renaming_mechanism) { :mac }

        it "writes a MAC based udev renaming rule" do
          expect(Y2Network::UdevRule).to receive(:write_net_rules) do |rules|
            expect(rules.first.to_s).to eq(
              "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", " \
                "ATTR{type}==\"1\", ATTR{dev_id}==\"0x0\", " \
                "ATTR{address}==\"01:23:45:67:89:ab\", NAME=\"eth1\""
            )
          end
          subject.write(interfaces)
        end
      end

      context "when the interface is renamed using the BUS ID" do
        let(:renaming_mechanism) { :bus_id }

        it "writes a BUS ID based udev renaming rule" do
          expect(Y2Network::UdevRule).to receive(:write_net_rules) do |rules|
            expect(rules.first.to_s).to eq(
              "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", " \
                "ATTR{type}==\"1\", KERNELS==\"00:1c.0\", ATTR{dev_port}==\"1\", NAME=\"eth1\""
            )
          end
          subject.write(interfaces)
        end
      end

      context "when there is some rule for an unknown interface" do
        let(:unknown_rule) do
          Y2Network::UdevRule.new_mac_based_rename("unknown", "00:11:22:33:44:55:66")
        end

        before do
          allow(Y2Network::UdevRule).to receive(:naming_rules).and_return([unknown_rule])
        end

        it "keeps the rule" do
          expect(Y2Network::UdevRule).to receive(:write_net_rules) do |rules|
            expect(rules.first.to_s).to eq(unknown_rule.to_s)
          end
          subject.write(interfaces)
        end
      end
    end

    context "when the interface is not renamed" do
      let(:renaming_mechanism) { nil }

      it "does not write a udev rule" do
        expect(Y2Network::UdevRule).to receive(:write_net_rules) do |rules|
          expect(rules).to be_empty
        end
        subject.write(interfaces)
      end
    end

    context "when a driver is set for an interface" do
      let(:driver) { "virtio_net" }

      it "writes an udev driver rule" do
        expect(Y2Network::UdevRule).to receive(:write_drivers_rules) do |rules|
          expect(rules.first.to_s).to eq(
            "ENV{MODALIAS}==\"#{hardware.modalias}\", ENV{MODALIAS}=\"#{driver}\""
          )
        end
        subject.write(interfaces)
      end
    end

    it "refreshes udev" do
      expect(Yast::Execute).to receive(:on_target).with("/usr/bin/udevadm", "control", any_args)
      expect(Yast::Execute).to receive(:on_target).with("/usr/bin/udevadm", "trigger", any_args)
      expect(Yast::Execute).to receive(:on_target).with("/usr/bin/udevadm", "settle")
      subject.write(interfaces)
    end
  end
end
