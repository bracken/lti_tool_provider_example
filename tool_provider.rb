require 'sinatra'
require 'ims/lti'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'

enable :sessions

set :protection, :only => [:admin_launch, :student_launch]

AVAILABLE_EXAMS = %w(exam1 exam2 exam3)

get '/' do
  @available_exams = AVAILABLE_EXAMS
  erb :index
end

# the consumer keys/secrets
$oauth_creds = {"test" => "secret"}

def show_error(message)
  @message = message
  erb :error
end

def verify_launch
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      @tp = IMS::LTI::ToolProvider.new(nil, nil, params)
      @tp.lti_msg = "Your consumer didn't use a recognized key."
      @tp.lti_errorlog = "You did it wrong!"
      return show_error "Consumer key wasn't recognized"
    end
  else
    return show_error "No consumer key"
  end

  if !@tp.valid_request?(request)
    return show_error "The OAuth signature was invalid"
  end

  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    return show_error "Your request is too old."
  end

  # this isn't actually checking anything like it should, just want people
  # implementing real tools to be aware they need to check the nonce
  if was_nonce_used_in_last_x_minutes?(@tp.request_oauth_nonce, 60)
    return show_error "Why are you reusing the nonce?"
  end

  true
end

post '/admin_launch' do
  res = verify_launch
  return res if res.is_a? String

  if !@tp.instructor?
    return show_error "This user isn't a teacher!"
  end

  if !@tp.lis_person_contact_email_primary
    return show_error "no email address sent for this launch. Expected the email in the key: lis_person_contact_email_primary"
  end

  if @exam = @tp.get_custom_param("measure_exam_id")
    if AVAILABLE_EXAMS.member?(@exam)
      erb :teacher_exam
    else
      return show_error "The exam '#{@exam}' doesn't exist"
    end
  else
    @available_exams = AVAILABLE_EXAMS
    erb :teacher_admin_area
  end
end
get '/admin_launch' do
  show_error "This must be launched as a POST not a get"
end

post '/student_launch' do
  res = verify_launch
  return res if res.is_a? String

  if !@tp.student?
    return show_error "This user isn't a student!"
  end

  if !@tp.lis_person_contact_email_primary
    return show_error "no email address sent for this launch. Expected the email in the key: lis_person_contact_email_primary"
  end


  session['launch_params'] = @tp.to_params
  if !@tp.outcome_service?
    return show_error "This wasn't launch as an outcome service launch, expected the keys: lis_outcome_service_url && lis_result_sourcedid"
  end

  if @exam = @tp.get_custom_param("measure_exam_id")
    if AVAILABLE_EXAMS.member?(@exam)
      erb :student_exam
    else
      return show_error "The exam '#{@exam}' doesn't exist"
    end
  else
    return show_error "No exam specified."
  end
end
get '/student_launch' do
  show_error "This must be launched as a POST not a get"
end

# post the assessment results
post '/finish_exam' do
  if session['launch_params']
    key = session['launch_params']['oauth_consumer_key']
  else
    return show_error "The tool never launched"
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], session['launch_params'])

  if !@tp.outcome_service?
    return show_error "This tool wasn't lunched as an outcome service"
  end

  res = @tp.post_replace_result!(params['score'])

  if res.success?
    @score = params['score']
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :exam_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the score."
    show_error "Your score was not recorded: #{res.description}"
  end
end

get '/admin_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/admin_launch"
  tc = IMS::LTI::ToolConfig.new(:title => "Measure admin link", :launch_url => url)
  tc.description = "The endpoint for a Measure admin launch. Can add custom_measure_exam_id to launch a specific exam"
  tc.set_custom_param("measure_exam_id", "exam1")

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end
get '/student_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/student_launch"
  tc = IMS::LTI::ToolConfig.new(:title => "Measure student link", :launch_url => url)
  tc.description = "The endpoint for a Measure student launch. Must add custom_measure_exam_id to launch a specific exam"
  tc.set_custom_param("measure_exam_id", "exam1")

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end
