require "rails_helper"

RSpec.describe ReceivePullRequestEvent do
  shared_examples "skipping due to labels" do
    context "and the PR has one of the configured ignore labels on it" do
      let(:ignore_labels_setting) { ["cody skip"] }
      let(:payload) { json_fixture("pull_request", action: action, body: body, labels: ["foobar", "cody skip"]) }

      it "does not call CreateOrUpdatePullRequest or perform any actions" do
        expect(CreateOrUpdatePullRequest).to_not receive(:new)
        job.perform(payload)
        expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
          .with { |req| JSON.parse(req.body)["state"] == "pending" }
      end
    end
  end

  let(:pull_request_number) { FactoryBot.generate(:pull_request_number) }
  let(:payload) { json_fixture("pull_request", action: action, body: body, number: pull_request_number) }

  let(:job) { ReceivePullRequestEvent.new }

  let(:body) do
    '- [ ] @aergonaut\n- [ ] @BrentW\n'
  end

  let(:min_reviewers) { 0 }
  let(:ignore_labels_setting) { nil }

  let(:repo) { FactoryBot.create :repository }

  before do
    stub_settings(
      repo,
      minimum_reviewers_required: min_reviewers,
      ignore_labels: ignore_labels_setting
    )
    allow(Repository).to receive(:find_by_full_name).and_return(repo)

    stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+/commits}).to_return(
      status: 200,
      body: json_fixture("pull_request_commits", committer_login: SecureRandom.hex).to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end

  describe "#perform" do
    before do
      stub_request(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
      stub_request(:patch, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/issues/\d+})
      stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+$}).to_return(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: JSON.dump(json_fixture("pr"))
      )
      stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/collaborators/[A-Za-z0-9_-]+}).to_return(status: 204)
      stub_request(:post, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+/requested_reviewers})
      stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+/requested_reviewers})
        .to_return(
          status: 200,
          body: JSON.dump({"users" => []}),
          headers: {"Content-Type" => "application/json"}
        )
      stub_request(:delete, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+/requested_reviewers})
    end

    context "when the action is \"opened\"" do
      let(:action) { "opened" }

      include_examples "skipping due to labels"

      context "when a minimum number of reviewers is required" do
        let(:min_reviewers) { 2 }

        context "and the PR does not have enough" do
          let(:min_reviewers) { 3 }

          it "puts the failure status on the commit" do
            job.perform(payload)
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
              .with { |req| JSON.parse(req.body)["state"] == "failure" }
          end

          it "does not make a new PullRequest record" do
            expect { job.perform(payload) }.to_not change { PullRequest.count }
          end
        end

        context "and there aren't enough unique reviewers" do
          let(:body) do
            '- [ ] @BrentW\n- [ ] @BrentW\n'
          end

          it "puts the failure status on the commit" do
            job.perform(payload)
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
              .with { |req| JSON.parse(req.body)["state"] == "failure" }
          end
        end
      end

      context "when no fatal errors are raised" do
        before do
          apply_rules = instance_double(ApplyReviewRules)
          expect(apply_rules).to receive(:perform)
          expect(ApplyReviewRules).to receive(:new).and_return(apply_rules)
        end

        it "creates a new PullRequest" do
          expect { job.perform(payload) }.to change { PullRequest.count }.by(1)
        end

        context "when some reviewers have already approved" do
          let(:body) do
            '- [ ] @aergonaut\n- [x] @BrentW\n'
          end

          it "creates Reviewers appropriately for each reviewer" do
            job.perform(payload)
            expect(PullRequest.last.reviewers.pending_review.map(&:login)).to contain_exactly("aergonaut")
            expect(PullRequest.last.reviewers.completed_review.map(&:login)).to contain_exactly("BrentW")
          end
        end

        context "when all of the reviewers have already approved" do
          let(:body) do
            '- [x] @aergonaut\n- [x] @BrentW\n'
          end

          it "marks the status as approved" do
            job.perform(payload)
            expect(PullRequest.last.status).to eq("approved")
          end
        end

        it "sends a POST request to GitHub" do
          job.perform(payload)
          expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
        end
      end
    end

    context "when the action is \"synchronize\"" do
      let(:action) { "synchronize" }

      include_examples "skipping due to labels"

      context "and we have recorded the PR" do
        let(:repo) { FactoryBot.create :repository, name: payload["repository"]["name"], owner: payload["repository"]["owner"]["login"] }
        let!(:pr) { FactoryBot.create :pull_request, number: payload["number"], repository: repo, status: status }

        before do
          job.perform(payload)
        end

        context "and the PR is pending" do
          let(:status) { "pending_review" }

          it "sends the pending review comment in the body" do
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
              .with { |req| JSON.parse(req.body)["description"] == "Not all reviewers have approved" }
          end
        end

        context "and the PR is approved" do
          let(:status) { "approved" }

          it "sends the review complete comment in the body" do
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
              .with { |req| JSON.parse(req.body)["description"] == "Code review complete" }
          end
        end
      end

      context "and we haven't yet recorded the PR" do
        it "delegates to CreateOrUpdatePullRequest" do
          expect(CreateOrUpdatePullRequest).to receive(:new).and_call_original
          job.perform(payload)
        end
      end
    end

    context "when the action is \"unlabeled\"" do
      let(:action) { "unlabeled" }

      before do
        expect(repo).to receive(:ignore?).and_return(repo_should_ignore).at_least(:once)
      end

      context "when the repository does not ignore the labels" do
        let(:repo_should_ignore) { false }

        context "and the PR has not been created" do
          it "calls CreateOrUpdatePullRequest" do
            mock = instance_double(CreateOrUpdatePullRequest)
            expect(CreateOrUpdatePullRequest).to receive(:new).and_return(mock)
            expect(mock).to receive(:perform)
            job.perform(payload)
          end
        end

        context "and the PR has been created" do
          before do
            FactoryBot.create :pull_request, number: pull_request_number, repository: repo
          end

          it "does not call CreateOrUpdatePullRequest" do
            expect(CreateOrUpdatePullRequest).to_not receive(:new)
            job.perform(payload)
          end
        end
      end

      context "when the repository ignores the labels" do
        let(:repo_should_ignore) { true }

        it "does not call CreateOrUpdatePullRequest" do
          expect(CreateOrUpdatePullRequest).to_not receive(:new)
          job.perform(payload)
        end
      end
    end
  end
end
