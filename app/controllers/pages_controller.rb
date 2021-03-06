###
#  Copyright (c) Microsoft. All rights reserved. Licensed under the MIT license.
#  See LICENSE in the project root for license information.
##

# The controller manages the interaction of the pages with
# Azure AD and graph.microsoft.com
# To see how to get tokens for your app look at the
# login, callback, and acquire_access_token
# To see how to send an email using the graph.microsoft.com
# endpoint see send_mail
# To see how to get rid of the tokens and finish the session
# in your app and Azure AD, see disconnect
class PagesController < ApplicationController
  skip_before_action :verify_authenticity_token

  # Create the authentication context, which receives
  # - Tenant
  # - Client ID and client secret
  # - The resource to be accessed, in this case graph.microsoft.com
  AUTH_CTX = ADAL::AuthenticationContext.new(
    'login.microsoftonline.com', 'common')
  CLIENT_CRED = ADAL::ClientCredential.new(
    ENV['CLIENT_ID'],
    ENV['CLIENT_SECRET'])
  GRAPH_RESOURCE = 'https://graph.microsoft.com'
  SENDMAIL_ENDPOINT = '/v1.0/me/microsoft.graph.sendmail'
  CONTENT_TYPE = 'application/json;odata.metadata=minimal;odata.streaming=true'

  # Delegates the browser to the Azure OmniAuth module
  # which takes the user to a sign-in page, if we don't have tokens already
  def login
    redirect_to '/auth/azureactivedirectory'
  end

  # If the user had to sign-in, the browser will redirect to this callback
  # with an authorization code attached
  # Then the app has to make a POST request to get tokens that it can use
  # for authenticated requests to resources in graph.microsoft.com
  # rubocop:disable Metrics/AbcSize
  def callback
    # Authentication redirects here
    code = params[:code]

    # Used in the template
    @name = auth_hash.info.name
    @email = auth_hash.info.email

    # Request an access token
    result = acquire_access_token(code, ENV['REPLY_URL'])

    # Associate token/user values to the session
    session[:access_token] = result.access_token
    session[:name] = @name
    session[:email] = @email

    # Debug logging
    logger.info "Code: #{code}"
    logger.info "Name: #{@name}"
    logger.info "Email: #{@email}"
    logger.info "[callback] - Access token: #{session[:access_token]}"
  end
  # rubocop:enable Metrics/AbcSize

  # Gets access (and refresh) token using the Azure OmniAuth library
  def acquire_access_token(auth_code, reply_url)
    AUTH_CTX.acquire_token_with_authorization_code(
      auth_code,
      reply_url,
      CLIENT_CRED,
      GRAPH_RESOURCE)
  end

  def auth_hash
    request.env['omniauth.auth']
  end

  # Sends an authenticated request to the sendmail endpoint in
  # graph.microsoft.com
  # The sendmail endpoint is
  # https://graph.microsoft.com/v1.0/me/microsoft.graph.sendmail
  # Stuff to consider:
  # - The email message is attached to the body of the request
  # - The access token must be appended to the authorization initheader
  # - Content type must be at least application/json
  # rubocop:disable Metrics/AbcSize
  def send_mail
    logger.debug "[send_mail] - Access token: #{session[:access_token]}"

    # Used in the template
    @name = session[:name]
    @email = params[:specified_email]
    @recipient = params[:specified_email]
    @mail_sent = false

    send_mail_endpoint = URI("#{GRAPH_RESOURCE}#{SENDMAIL_ENDPOINT}")
    content_type = CONTENT_TYPE
    http = Net::HTTP.new(send_mail_endpoint.host, send_mail_endpoint.port)
    http.use_ssl = true

    # If you want to use a sniffer tool, like Fiddler, to see the request
    # you might need to add this line to tell the engine not to verify the
    # certificate or you might see a "certificate verify failed" error
    # http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    email_body = File.read('app/assets/MailTemplate.html')
    email_body.sub! '{given_name}', @name

    logger.debug email_body

    email_message = "{
            Message: {
            Subject: 'Welcome to Office 365 development with Ruby',
            Body: {
                ContentType: 'HTML',
                Content: '#{email_body}'
            },
            ToRecipients: [
                {
                    EmailAddress: {
                        Address: '#{@recipient}'
                    }
                }
            ]
            },
            SaveToSentItems: true
            }"

    response = http.post(
      SENDMAIL_ENDPOINT,
      email_message,
      'Authorization' => "Bearer #{session[:access_token]}",
      'Content-Type' => content_type
    )

    logger.debug "Code: #{response.code}"
    logger.debug "Message: #{response.message}"

    # The send mail endpoint returns a 202 - Accepted code on success
    if response.code == '202'
      @mail_sent = true
    else
      @mail_sent = false
      flash[:httpError] = "#{response.code} - #{response.message}"
    end

    render 'callback'
  end
  # rubocop:enable Metrics/AbcSize

  # Deletes the local session and sends the browser to the logout endpoint
  # so Azure AD has a chance to handle its own logout flow
  # After Azure AD is done, it redirects the browser to the value in
  # post_logout_redirect_uri, which happens to be our start screen
  def disconnect
    reset_session
    redirect = "#{ENV['LOGOUT_ENDPOINT']}"\
               "?post_logout_redirect_uri=#{ERB::Util.url_encode(root_url)}"
    logger.info 'REDIRECT: ' + redirect
    redirect_to redirect
  end
end
