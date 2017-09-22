require "rails_helper"

RSpec.describe Clients::VispdatsController, type: :routing do
  describe "routing" do
    ['clients', 'window/clients'].each do |client_path|
      it "routes to #index" do
        expect(:get => "#{client_path}/1/vispdats").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'index',
          client_id: '1'
        )
      end

      it "routes to #new" do
        expect(:get => "#{client_path}/1/vispdats/new").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'new',
          client_id: '1'
        )
      end

      it "routes to #show" do
        expect(:get => "#{client_path}/1/vispdats/1").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'show',
          client_id: '1',
          id: "1"
        )
      end

      it "routes to #edit" do
        expect(:get => "#{client_path}/1/vispdats/1/edit").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'edit',
          id: "1",
          client_id: '1',
        )
      end

      it "routes to #create" do
        expect(:post => "#{client_path}/1/vispdats").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'create',
          client_id: '1',
        )
      end

      it "routes to #update via PUT" do
        expect(:put => "#{client_path}/1/vispdats/1").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'update',
          id: "1",
          client_id: '1',
        )
      end

      it "routes to #update via PATCH" do
        expect(:patch => "#{client_path}/1/vispdats/1").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'update',
          id: "1",
          client_id: '1'
        )
      end

      it "routes to #destroy" do
        expect(:delete => "#{client_path}/1/vispdats/1").to route_to(
          controller: "#{client_path}/vispdats",
          action: 'destroy',
          id: "1",
          client_id: '1'
        )
      end
    end
  end
end
