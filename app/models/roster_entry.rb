# frozen_string_literal: true

class RosterEntry < ApplicationRecord
  class IdentifierCreationError < StandardError; end

  include Sortable
  include Searchable
  include DuplicateRosterEntries

  belongs_to :roster
  belongs_to :user, optional: true

  validates :identifier, presence: true
  validates :roster,     presence: true

  scope :order_by_repo_created_at, lambda { |context|
    assignment = context[:assignment]
    sql_formatted_assignment_id = assignment.id

    order("assignment_repos.created_at")
      .joins <<~SQL
        LEFT OUTER JOIN assignment_repos
        ON roster_entries.user_id = assignment_repos.user_id
        AND assignment_repos.assignment_id='#{sql_formatted_assignment_id}'
      SQL
  }

  scope :order_by_student_identifier, ->(_context = nil) { order(identifier: :asc) }

  scope :search_by_student_identifier, ->(query) { where("identifier ILIKE ?", "%#{query}%") }

  def self.sort_modes
    {
      "Student identifier" => :order_by_student_identifier,
      "Created at" => :order_by_repo_created_at
    }
  end

  def self.search_mode
    :search_by_student_identifier
  end

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity
  def self.to_csv(user_to_group_map = {})
    CSV.generate(headers: true, col_sep: ",", force_quotes: true) do |csv|
      columns = %i[identifier github_username github_id name]
      columns << :group_name unless user_to_group_map.empty?
      csv << columns

      all.sort_by(&:identifier).each do |entry|
        github_user = entry.user.try(:github_user)
        login = github_user.try(:login) || ""
        github_id = github_user.try(:id) || ""
        name = github_user.try(:name) || ""
        group_name = user_to_group_map.empty? ? "" : user_to_group_map[entry.user_id]

        row = [entry.identifier, login, github_id, name]
        row << group_name if group_name.present?
        csv << row
      end
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity

  # Orders the relation for display in a view.
  # Ordering is:
  # first:  Accepted the assignment
  # second: Linked but not accepted
  # last:   Unlinked student
  #
  # To display all the roster entries that have accepted the assignment first,
  # we perform a LEFT JOIN operation. But for this order to work correctly,
  # we should also verify if the join operation resulted in a match. Hence the query
  # to find accepted students adds an extra check for assignment_repos.user_id NOT NULL.
  # For more context visit: https://github.com/education/classroom/pull/2237
  #
  # rubocop:disable Metrics/MethodLength
  def self.order_for_view(assignment)
    join_sql = <<~SQL
      LEFT JOIN assignment_repos
      ON roster_entries.user_id = assignment_repos.user_id
      AND assignment_repos.assignment_id = #{assignment.id}
    SQL

    order_sql = <<~SQL
      CASE
        WHEN roster_entries.user_id IS NULL THEN 2                  /* Not linked */
        WHEN roster_entries.user_id IS NOT NULL
          AND assignment_repos.user_id IS NOT NULL THEN 0           /* Accepted */
        ELSE 1                                                      /* Linked but not accepted */
      END
    SQL

    joins(join_sql).order(order_sql)
  end
  # rubocop:enable Metrics/MethodLength

  # Restrict relation to only entries that have not joined a team
  def self.students_not_on_team(group_assignment)
    students_on_team = group_assignment
      .repos
      .includes(:repo_accesses)
      .flat_map(&:repo_accesses)
      .map(&:user_id)
      .uniq
    where(user_id: nil).or(where.not(user_id: students_on_team))
  end
end
