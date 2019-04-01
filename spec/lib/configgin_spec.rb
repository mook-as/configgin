require 'spec_helper'
require 'configgin'

describe Configgin do
  let(:options) {
    {
      jobs: fixture('nats-job-config.json'),
      env2conf: fixture('nats-env2conf.yml'),
      bosh_deployment_manifest: nil,
      self_name: 'pod-0'
    }
  }
  let(:client) {
    MockKubeClient.new(fixture('state.yml'))
  }
  subject {
    described_class.new(options)
  }

  before(:each) {
    allow(subject).to receive(:render_job_templates)
    allow(subject).to receive(:kube_namespace).and_return('the-namespace')
    allow(subject).to receive(:kube_token).and_return('abcdefg')
    allow(subject).to receive(:kube_client).and_return(client)
    allow(subject).to receive(:kube_client_stateful_set).and_return(client)
    allow(subject).to receive(:instance_group).and_return('instance-group')
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with('/var/vcap/jobs-src/loggregator_agent/config_spec.json')
      .and_return(File.read(fixture('nats-loggregator-config-spec.json')))
  }

  describe '#run' do
    it 'reads the namespace' do
      expect(Job).to receive(:new).with(hash_including(namespace: 'the-namespace')).and_call_original
      subject.run
    end

    it 'uses default values' do
      expect(Job).to receive(:new).and_wrap_original do |original, arguments|
        expect(arguments[:spec]['properties']['loggregator']['tls']['agent']['cert']).to eq('')
        original.call(arguments)
      end
      subject.run
    end

    context 'with ENV variables' do
      before(:each) {
        stub_const('ENV', 'LOGGREGATOR_AGENT_CERT' => 'FOO')
      }
      it 'considers ENV variables in templates' do
        expect(Job).to receive(:new).and_wrap_original do |original, arguments|
          expect(arguments[:spec]['properties']['loggregator']['tls']['agent']['cert']). to eq('FOO')
          original.call(arguments)
        end

        subject.run
      end
    end

    context 'with a bosh deployment manifest' do
      subject {
        described_class.new(options.merge(bosh_deployment_manifest: File.expand_path('fixtures/nats-manifest.yml', __dir__)))
      }

      it 'considers values from the bosh manifest' do
        expect(subject).to receive(:instance_group).and_return('nats-server')
        expect(Job).to receive(:new).and_wrap_original do |original, arguments|
          expect(arguments[:spec]['properties']['tls']['agent']['cert']). to eq('BAR')
          original.call(arguments)
        end

        subject.run
      end
    end

    it 'patches affected statefulsets' do
      subject.run
      pod = client.get_pod('pod-0', 'the-namespace')
      expect(pod).not_to be_nil
      statefulset = client.get_stateful_set('debugger', 'the-namespace')
      expect(statefulset).not_to be_nil

      exported_key = 'skiff-exported-digest-loggregator_agent'
      imported_key = 'skiff-imported-properties-instance-group-loggregator_agent'
      expect(statefulset.spec.template.metadata.annotations[imported_key]).to eq pod.metadata.annotations[exported_key]
    end
  end
end
