require "rails_helper"

RSpec.describe PullRequest, type: :model do
  it { is_expected.to belong_to :repository }

  it { is_expected.to validate_numericality_of :number }
  it { is_expected.to validate_presence_of :number }
  it { is_expected.to validate_presence_of :status }

  describe ".pending_review" do
    let(:pending_review_pr) { FactoryBot.create :pull_request, status: "pending_review" }
    let(:approved_pr) { FactoryBot.create :pull_request, status: "approved" }

    subject { PullRequest.pending_review }

    it { is_expected.to include(pending_review_pr) }
    it { is_expected.to_not include(approved_pr) }
  end

  let(:pr) { build :pull_request }

  describe "#update_status" do
    let(:pull_request_response_body) { json_fixture("pr") }
    let(:pr_number) { pull_request_response_body["number"] }
    let(:repo_full_name) { pull_request_response_body["base"]["repo"]["full_name"] }
    let(:head_sha) { pull_request_response_body["head"]["sha"] }
    let(:repository) { FactoryBot.create :repository, owner: repo_full_name.split("/", 2)[0], name: repo_full_name.split("/", 2)[1] }

    let(:pr) { build :pull_request, number: pr_number, repository: repository }

    before do
      stub_request(:get, "https://api.github.com/repos/#{repo_full_name}/pulls/#{pr_number}").to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: JSON.dump(json_fixture("pr"))
      )
      stub_request(:post, "https://api.github.com/repos/#{repo_full_name}/statuses/#{head_sha}")
    end

    it "posts to the GitHub API" do
      pr.update_status
      expect(WebMock).to have_requested(:post, "https://api.github.com/repos/#{repo_full_name}/statuses/#{head_sha}")
    end
  end

  describe "#head_sha" do
    let(:pull_request_response_body) { json_fixture("pr") }
    let(:pr_number) { pull_request_response_body["number"] }
    let(:repo_full_name) { pull_request_response_body["base"]["repo"]["full_name"] }
    let(:head_sha) { pull_request_response_body["head"]["sha"] }
    let(:repository) { FactoryBot.create :repository, owner: repo_full_name.split("/", 2)[0], name: repo_full_name.split("/", 2)[1] }

    let(:pr) { build :pull_request, number: pr_number, repository: repository }

    before do
      stub_request(:get, "https://api.github.com/repos/#{repo_full_name}/pulls/#{pr_number}").to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: JSON.dump(json_fixture("pr"))
      )
    end

    it "returns the SHA from the API response" do
      expect(pr.head_sha).to eq(head_sha)
    end
  end

  describe "#commit_authors" do
    let(:pr) { FactoryBot.create :pull_request, status: "pending_review" }

    before do
      stub_request(:get, %r{https?://api.github.com/repos/#{pr.repository.owner}/#{pr.repository.name}/pulls/#{pr.number}/commits}).to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: json_fixture("pull_request_commits", committer_login: "aergonaut").to_json
      )
    end

    subject { pr.commit_authors }

    it "returns array of commit authors" do
      expect(subject).to contain_exactly("aergonaut")
    end

    context "without a repository" do
      # legacy case
      it "returns []" do
        allow(pr).to receive(:repository).and_return(nil)
        expect(pr.commit_authors).to be_empty
      end
    end
  end

  describe "#link_by_number" do
    let(:pr) { FactoryBot.build :pull_request }
    let(:parent_number) { 1234 }

    context "when the parent PR is known to Cody" do
      let!(:parent) { FactoryBot.create :pull_request, status: "pending_review", number: parent_number, repository: pr.repository }

      it "returns truthy, sets the parent, copies the status, and persists the object" do
        expect(pr.link_by_number(parent_number)).to be_truthy
        expect(pr.parent_pull_request).to eq(parent)
        expect(pr.status).to eq(parent.status)
        expect(pr).to be_persisted
      end
    end

    context "when the parent PR is not known to Cody" do
      it "returns falsey, does not persist the object" do
        expect(pr.link_by_number(parent_number)).to be_falsey
        expect(pr).to_not be_persisted
      end
    end
  end

  describe "updating child PRs" do
    let!(:pr) { FactoryBot.create :pull_request, status: "pending_review", number: 1234 }
    let!(:child) { FactoryBot.build :pull_request, repository: pr.repository }

    before do
      child_pr = json_fixture("pr")
      child_pr["number"] = child.number
      stub_request(:get, %r{https://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/#{child.number}}).to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: child_pr.to_json
      )

      pr_1234 = json_fixture("pr")
      pr_1234["number"] = 1234
      stub_request(:get, %r{https://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/1234}).to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: pr_1234.to_json
      )

      stub_request(:post, "https://api.github.com/repos/#{child.repository.owner}/#{child.repository.name}/statuses/#{child.head_sha}")

      child.link_by_number(1234)
    end

    it "updates all child PRs when the status changes" do
      pr.status = "approved"
      pr.save!
      expect(child.reload.status).to eq(pr.status)
      expect(WebMock).to have_requested(:post, "https://api.github.com/repos/#{child.repository.owner}/#{child.repository.name}/statuses/#{child.head_sha}")
        .with { |request|
          json_body = JSON.parse(request.body)
          json_body["state"] == "success"
        }
    end
  end
end
