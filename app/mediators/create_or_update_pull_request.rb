# frozen_string_literal: true

class CreateOrUpdatePullRequest
  include GithubApi

  # Public: Creates or updates a Pull Request record in reponse to a webhook
  #
  # pull_request - A Hash-like object containing the PR data from the GitHub API
  # options - Hash of options
  #           :skip_review_rules - Boolean to apply review rules or skip
  # rubocop:disable Layout/LineLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def perform(pull_request, options = {})
    body = pull_request["body"] || ""
    repository = Repository.find_by_full_name(pull_request["base"]["repo"]["full_name"])

    pr = repository.pull_requests.find_or_initialize_by(
      number: pull_request["number"]
    )

    github = github_client

    if PullRequest::REVIEW_LINK_REGEX.match?(body)
      # if pr.link_by_number(Regexp.last_match(1))
      #   pr.update_status
      #   return
      # end
    elsif pr.parent_pull_request.present?
      pr.parent_pull_request = nil
      pr.save!
    end

    prelude, _ = body.split(ReviewRule::GENERATED_REVIEWERS_REGEX, 2)
    prelude ||= ""

    # Collect reviewers listed in the PR prelude.
    check_box_pairs = prelude.scan(PullRequest::REVIEWER_CHECKBOX_REGEX)

    # uniqueness by reviewer login
    check_box_pairs.uniq! { |pair| pair[1] }

    # Check for committers assigning themselves for review
    check_box_logins = check_box_pairs.map { |pair| pair[1] }
    reviewers_who_are_committers = (check_box_logins & pr.commit_authors)
    unless reviewers_who_are_committers.empty?
      verb_phrase =
        if reviewers_who_are_committers.count > 1
          "are committers"
        else
          "is a committer"
        end

      reviewers = reviewers_who_are_committers.join(", ")
      pr.update_status(
        format(
          PullRequest::STATUS_BANANA,
          {reviewers: reviewers, verb_phrase: verb_phrase}
        )
      )
      return
    end

    minimum_reviewers_required = repository.read_setting("minimum_reviewers_required")
    if minimum_reviewers_required.present? &&
        check_box_pairs.count < minimum_reviewers_required

      pr.update_status(PullRequest::STATUS_APRICOT)
      return
    end

    pending_reviews = []
    completed_reviews = []

    check_box_pairs.each do |pair|
      if pair[0] == "x"
        completed_reviews << pair[1].strip
      else
        pending_reviews << pair[1].strip
      end
    end

    all_reviewers = pending_reviews + completed_reviews

    reviewers_without_access = pending_reviews.reject { |reviewer|
      github.collaborator?(pr.repository.full_name, reviewer)
    }

    unless reviewers_without_access.empty?
      verb_phrase =
        if reviewers_without_access.count > 1
          "are not collaborators"
        else
          "is not a collaborator"
        end

      reviewers_phrase = reviewers_without_access.join(", ")

      pr.update_status(
        format(
          PullRequest::STATUS_PLUM,
          {reviewers: reviewers_phrase, verb_phrase: verb_phrase}
        )
      )
      return
    end

    pr.status = "pending_review"

    pr.save!

    # Synchronize the reviewers
    all_reviewers.each do |login|
      # we only respect manual updates to non-generated reviewers
      reviewer = pr.reviewers.find_by(login: login, review_rule_id: nil)
      if reviewer.present?
        # they were on the list previously
        if completed_reviews.include?(login)
          # marked done
          reviewer.update!(status: Reviewer::STATUS_APPROVED)
        elsif pending_reviews.include?(login)
          # marked undone
          reviewer.update!(status: Reviewer::STATUS_PENDING_APPROVAL)
        else
          # removed from the list altogether
          reviewer.destroy!
        end
      # they weren't on the list previously
      elsif completed_reviews.include?(login)
        # marked down
        pr.reviewers.create!(login: login, status: Reviewer::STATUS_APPROVED)
      else
        # otherwise they're marked undone
        pr.reviewers.create!(
          login: login,
          status: Reviewer::STATUS_PENDING_APPROVAL
        )
      end
    end

    # Destroy reviewers who were on the list before but aren't any longer
    pr.reviewers
      .where(review_rule_id: nil)
      .where("reviewers.login NOT IN (?)", all_reviewers)
      .destroy_all

    unless options[:skip_review_rules]
      ApplyReviewRules.new(pr, pull_request).perform
    end

    pr.reload

    status =
      if !pr.reviewers.pending_review.empty?
        "pending_review"
      else
        "approved"
      end

    pr.status = status
    pr.save!

    pr.update_status
    pr.assign_reviewers

    current_requested_reviews =
      github_client.pull_request_review_requests(
        pr.repository.full_name,
        pr.number
      ).users.map(&:login)

    reviews_to_remove = current_requested_reviews - pr.pending_review_logins
    github_client.delete_pull_request_review_request(
      pr.repository.full_name,
      pr.number,
      reviewers: reviews_to_remove
    )
  end
  # rubocop:enable Layout/LineLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
end
