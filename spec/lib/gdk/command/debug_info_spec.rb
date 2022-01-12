# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GDK::Command::DebugInfo do
  let(:gdk_root) { Pathname.new('/home/git/gdk') }
  let(:args) { [] }
  let(:shellout) { double(run: true) }

  subject { described_class.new.run(args) }

  before do
    allow(GDK).to receive(:root).and_return(gdk_root)
    allow(GDK::Output).to receive(:puts)
    allow(File).to receive(:exist?).with(GDK::Config::FILE).and_return(false)

    stub_shellout_response('uname -a', 'exampleOS')
    stub_shellout_response('arch', 'example_arch')
    stub_shellout_response('ruby --version', '1.2.3')
    stub_shellout_response('git rev-parse --short HEAD', 'abcdef')
  end

  describe '#run' do
    it 'displays debug information and returns true' do
      expect_output('Operating system: exampleOS')
      expect_output('Architecture: example_arch')
      expect_output('Ruby version: 1.2.3')
      expect_output('GDK version: abcdef')

      expect(subject).to be(true)
    end

    context 'gdk.yml is present' do
      let(:gdk_yml) { { example: :config }.to_yaml }

      before do
        allow(File).to receive(:exist?).with(GDK::Config::FILE).and_return(true)
        allow(File).to receive(:read).with(GDK::Config::FILE).and_return(gdk_yml)
      end

      it 'includes gdk.yml contents in the debug output' do
        expect_output('GDK configuration:')
        expect_output(gdk_yml)

        expect(subject).to be(true)
      end
    end

    context 'an error is raised during shellout' do
      before do
        allow(Shellout).to receive(:new).with('uname -a').and_raise('halt and catch fire')
      end

      it 'displays the error message and continues' do
        expect_output('Operating system: Unknown (halt and catch fire)')

        expect(subject).to be(true)
      end
    end
  end

  def stub_shellout_response(cmd, response)
    shellout = double(run: response)

    allow(Shellout).to receive(:new).with(cmd, any_args).and_return(shellout)
  end

  def expect_output(message)
    expect(GDK::Output).to receive(:puts).with(message)
  end
end
