# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Asdf::ToolVersion do
  let(:name) { 'golang' }
  let(:version) { '1.17.2' }

  subject { described_class.new(name, version) }

  describe '#uninstall!' do
    let(:success) { nil }
    let(:shellout_double) { instance_double(Shellout, success?: success) }

    before do
      allow(Shellout).to receive(:new).with("asdf uninstall #{name} #{version}").and_return(shellout_double)
      allow(shellout_double).to receive(:execute).and_return(shellout_double)
    end

    context 'when uninstall fails' do
      let(:success) { false }

      it 'raises an UninstallFailedError exception' do
        expect { subject.uninstall! }.to raise_error(Asdf::ToolVersion::UninstallFailedError)
      end
    end

    context 'when uninstall succeeds' do
      let(:success) { true }

      it 'returns true' do
        expect(subject.uninstall!).to be_truthy
      end
    end
  end
end
