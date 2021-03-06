# @API Blueprint Templates
# @beta
# Configure blueprint courses
#
# @model BlueprintTemplate
#   {
#     "id" : "BlueprintTemplate",
#     "description" : "",
#     "properties": {
#       "id": {
#         "description": "The ID of the template.",
#         "example": 1,
#         "type": "integer",
#         "format": "int64"
#       },
#       "course_id": {
#         "description": "The ID of the Course the template belongs to.",
#         "example": 2,
#         "type": "integer",
#         "format": "int64"
#       },
#       "last_export_completed_at": {
#         "description": "Time when the last export was completed",
#         "example": "2013-08-28T23:59:00-06:00",
#         "type": "datetime"
#        }
#     }
#   }
#
class MasterCourses::MasterTemplatesController < ApplicationController
  before_action :require_master_courses
  before_action :get_template

  include Api::V1::Course
  include Api::V1::MasterTemplate

  # @API Get blueprint information
  #
  # Using 'default' as the template_id should suffice for the current implmentation (as there should be only one template per course).
  # However, using specific template ids may become necessary in the future
  #
  # @returns BlueprintTemplate
  #
  # @example_request
  #     curl https://<canvas>/api/v1/courses/1/blueprint_templates/default \
  #       -H 'Authorization: Bearer <ACCESS_TOKEN>'
  #
  def show
    render :json => master_template_json(@template, @current_user, session)
  end

  # @API Get associated course information
  #
  # Returns a list of courses that are configured to receive updates from this blueprint
  #
  # @returns [Course]
  #
  # @example_request
  #     curl https://<canvas>/api/v1/courses/1/blueprint_templates/default/associated_courses \
  #       -H 'Authorization: Bearer <ACCESS_TOKEN>'
  #
  def associated_courses
    scope = @template.child_course_scope.order(:id).preload(:enrollment_term, :teachers)
    courses = Api.paginate(scope, self, api_v1_course_blueprint_associated_courses_url)
    can_read_sis = @course.account.grants_any_right?(@current_user, :read_sis, :manage_sis)

    json = courses.map do |course|
      # could use course_json but at this point it's got so much overhead...
      hash = api_json(course, @current_user, session, :only => %w{id name course_code})
      hash['sis_course_id'] = course.sis_source_id if can_read_sis
      hash['term_name'] = course.enrollment_term.name
      hash['teachers'] = course.teachers.map { |teacher| user_display_json(teacher) }
      hash
    end
    render :json => json
  end

  # @API Update associated courses
  #
  # Send a list of course ids to add or remove new associations for the template.
  # Cannot add courses that do not belong to the blueprint course's account. Also cannot add
  # other blueprint courses or courses that already have an association with another blueprint course.
  #
  # @argument course_ids_to_add [Array]
  #   Courses to add as associated courses
  #
  # @argument course_ids_to_remove [Array]
  #   Courses to remove as associated courses
  #
  # @example_request
  #     curl https://<canvas>/api/v1/courses/1/blueprint_templates/default/update_associations \
  #     -X PUT \
  #     -H 'Authorization: Bearer <token>' \
  #     -d 'course_ids_to_add[]=1' \
  #     -d 'course_ids_to_remove[]=2' \
  #
  def update_associations
    if authorized_action(@course.account, @current_user, :manage_courses)
      # note that I'm additionally requiring course management rights on the account
      # since (for now) we're only allowed to associate courses derived from it
      ids_to_add = Array(params[:course_ids_to_add]).map(&:to_i)
      ids_to_remove = Array(params[:course_ids_to_remove]).map(&:to_i)
      if (ids_to_add & ids_to_remove).any?
        return render :json => {:message => "cannot add and remove a course at the same time"}, :status => :bad_request
      end

      if ids_to_add.any?
        valid_ids_to_add = @course.account.associated_courses.where.not(:workflow_state => "deleted").
          not_master_courses.where(:id => ids_to_add).pluck(:id)
        invalid_ids = ids_to_add - valid_ids_to_add
        if invalid_ids.any?
          return render :json => {:message => "invalid courses to add (#{invalid_ids.join(", ")})"}, :status => :bad_request
        end

        data = MasterCourses::ChildSubscription.active.where(:child_course_id => valid_ids_to_add).pluck(:master_template_id, :child_course_id)
        template_pairs, other_pairs = data.partition{|template_id, c_id| template_id == @template.id}
        if other_pairs.any?
          # i still think there's a case for multiple inheritance but for now...
          return render :json => {:message => "cannot add courses already associated with other templates (#{other_pairs.map(&:last).join(", ")})"}, :status => :bad_request
        end

        valid_ids_to_add -= template_pairs.map(&:last) # ignore existing active subscriptions
        valid_ids_to_add.each { |course_id| @template.add_child_course!(course_id) }
      end

      if ids_to_remove.any?
        @template.child_subscriptions.active.where(:child_course_id => ids_to_remove).update_all(:workflow_state => 'deleted')
      end

      render :json => {:success => true}
    end
  end

  protected
  def require_master_courses
    render_unauthorized_action unless master_courses?
  end

  def get_template
    @course = api_find(Course, params[:course_id])
    if authorized_action(@course.account, @current_user, :manage_master_courses)
      mc_scope = @course.master_course_templates.active
      template_id = params[:template_id]
      if template_id == 'default'
        @template = mc_scope.for_full_course.first
        raise ActiveRecord::RecordNotFound unless @template
      else
        @template = mc_scope.find(template_id)
      end
    else
      false
    end
  end
end
