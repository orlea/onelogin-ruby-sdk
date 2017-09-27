require 'onelogin/version'
require 'onelogin/api/util'
require 'onelogin/api/cursor'
require 'json'
require 'httparty'
require 'nokogiri'
require 'time'

module OneLogin
  module Api
    # Client class
  	#
  	# Client class of the OneLogin's Ruby SDK.
  	# It makes the API calls to the Onelogin's platform described
    # at https://developers.onelogin.com/api-docs/1/getting-started/dev-overview.
  	#
    class Client
      include OneLogin::Api::Util

      attr_accessor :client_id, :client_secret, :region
      attr_accessor :user_agent, :error, :error_description

      NOKOGIRI_OPTIONS = Nokogiri::XML::ParseOptions::STRICT |
                         Nokogiri::XML::ParseOptions::NONET

      DEFAULT_USER_AGENT = "onelogin-ruby-sdk v#{OneLogin::VERSION}".freeze

      # Create a new instance of the Client.
      #
      # @param config [Hash] Client Id, Client Secret and Region
      #
      def initialize(config)
        options = Hash[config.map { |(k, v)| [k.to_sym, v] }]

        @client_id = options[:client_id]
        @client_secret = options[:client_secret]
        @region = options[:region] || 'us'

        validate_config

        @user_agent = DEFAULT_USER_AGENT
      end

      def validate_config
        raise ArgumentError, 'client_id & client_secret are required' unless @client_id && @client_secret
      end

      # Clean any previous error registered at the client.
      #
      def clean_error
        @error = nil
        @error_description = nil
      end

      def extract_error_message_from_response(response)
        message = ''
        content = JSON.parse(response.body)
        if content && content.has_key?('status')
          status = content['status']
          if status.has_key?('message')
            message = status['message']
          elsif status.has_key?('type')
            message = status['type']
          end
        end
        message
      end

      def get_after_cursor(response)
        content = JSON.parse(response.body)
        if content && content.has_key?('pagination') && content['pagination'].has_key?('after_cursor')
          content['pagination']['after_cursor']
        end
      end

      def get_before_cursor(response)
        content = JSON.parse(response.body)
        if content && content.has_key?('pagination') && content['pagination'].has_key?('before_cursor')
          content['pagination']['before_cursor']
        end
      end

      def retrieve_apps_from_xml(xml_content)
        doc = Nokogiri::XML(xml_content) do |config|
          config.options = NOKOGIRI_OPTIONS
        end

        node_list = doc.xpath("/apps/app")
        attributes = ['id', 'icon', 'name', 'provisioned', 'extension_required', 'personal', 'login_id']
        apps = []
        node_list.each do |node|
          app_data = {}
          node.children.each do |children|
            if attributes.include? children.name
              app_data[children.name] = children.content
            end
          end
          apps << OneLogin::Api::Models::App.new(app_data)
        end

        apps
      end

      def expired?
        Time.now.utc > @expiration
      end

      def prepare_token
        if @access_token.nil?
          get_access_token
        elsif expired?
          regenerate_token
        end
      end

      def handle_operation_response(response)
        result = false
        begin
          content = JSON.parse(response.body)
          if content && content.has_key?('status') && content['status'].has_key?('type') && content['status']['type'] == "success"
            result = true
          end
        rescue Exception => e
          result = false
        end

        result
      end

      def handle_session_token_response(response)
        content = JSON.parse(response.body)
        if content && content.has_key?('status') && content['status'].has_key?('message') && content.has_key?('data')
          if content['status']['message'] == "Success"
            return OneLogin::Api::Models::SessionTokenInfo.new(content['data'][0])
          elsif content['status']['message'] == "MFA is required for this user"
            return OneLogin::Api::Models::SessionTokenMFAInfo.new(content['data'][0])
          else
            raise "Status Message type not reognized: %s" % content['status']['message']
          end
        end

        nil
      end

      def handle_saml_endpoint_response(response)
        content = JSON.parse(response.body)
        if content && content.has_key?('status') && content.has_key?('data') && content['status'].has_key?('message') && content['status'].has_key?('type')
          status_type = content['status']['type']
          status_message = content['status']['message']
          saml_endpoint_response = OneLogin::Api::Models::SAMLEndpointResponse.new(status_type, status_message)
          if status_message == 'Success'
            saml_endpoint_response.saml_response = content['data']
          else
            mfa = OneLogin::Api::Models::MFA.new(content['data'][0])
            saml_endpoint_response.mfa = mfa
          end

          return saml_endpoint_response
        end

        nil
      end

      def authorization_header(bearer = true)
        if bearer
          "bearer:#{@access_token}"
        else
          "client_id:#{@client_id},client_secret:#{@client_secret}"
        end
      end
      alias get_authorization authorization_header

      def request_headers
        {
          'Authorization' => authorization_header,
          'Content-Type' => 'application/json',
          'User-Agent' => @user_agent
        }
      end

      ############################
      # OAuth 2.0 Tokens Methods #
      ############################

      # Generates an access token and refresh token that you may use to
      # call Onelogin's API methods.
      #
      # @return [OneLoginToken] Returns the generated OAuth Token info
      #
      # @see {https://developers.onelogin.com/api-docs/1/oauth20-tokens/generate-tokens Generate Tokens documentation}
      def get_access_token
        clean_error

        begin

          url = get_url(TOKEN_REQUEST_URL)

          authorization = get_authorization(false)

          data = {
            'grant_type' => 'client_credentials'
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              token = OneLogin::Api::Models::OneLoginToken.new(json_data['data'][0])
              @access_token = token.access_token
              @refresh_token = token.refresh_token
              @expiration = token.created_at + token.expires_in
              return token
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Refreshing tokens provides a new set of access and refresh tokens.
      #
      # @return [OneLoginToken] Returns the refreshed OAuth Token info
      #
      # @see {https://developers.onelogin.com/api-docs/1/oauth20-tokens/refresh-tokens Refresh Tokens documentation}
      def regenerate_token
        clean_error

        begin

          url = get_url(TOKEN_REQUEST_URL)

          data = {
            'grant_type' => 'refresh_token',
            'access_token' => @access_token,
            'refresh_token' => @refresh_token
          }

          headers = {
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              token = OneLogin::Api::Models::OneLoginToken.new(json_data['data'][0])
              @access_token = token.access_token
              @refresh_token = token.refresh_token
              @expiration = token.created_at + token.expires_in
              return token
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Revokes an access token and refresh token pair.
      #
      # @return [Boolean] If the opeation succeded
      #
      # @see {https://developers.onelogin.com/api-docs/1/oauth20-tokens/revoke-tokens Revoke Tokens documentation}
      def revoke_token
        clean_error

        begin

          url = get_url(TOKEN_REVOKE_URL)

          authorization = get_authorization(false)

          data = {
            'access_token' => @access_token
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            @access_token = nil
            @refresh_token = nil
            @expiration = nil
            return true
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Gets current rate limit details about an access token.
      #
      # @return [RateLimit] Returns the rate limit info
      #
      # @see {https://developers.onelogin.com/api-docs/1/oauth20-tokens/get-rate-limit Get Rate Limit documentation}
      def get_rate_limits
        clean_error
        prepare_token

        begin

          url = get_url(GET_RATE_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::RateLimit.new(json_data['data'])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      ################
      # User Methods #
      ################

      # Gets a list of User resources. (if no limit provided, by default gt 50 elements)
      #
      # @param params [Hash] Parameters to filter the result of the list
      #
      # @return [Array] list of User objects
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/get-users Get Users documentation}
      def get_users(params = {})
        clean_error
        prepare_token

        begin
          options = {
            model: OneLogin::Api::Models::User,
            headers: request_headers
          }

          return Cursor.new(get_url(GET_USERS_URL), options)

        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets User by ID.
      #
      # @param user_id [Integer] Id of the user
      #
      # @return [User] the user identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/get-user-by-id Get User by ID documentation}
      def get_user(user_id)
        clean_error
        prepare_token

        begin

          url = get_url(GET_USER_URL, user_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::User.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets a list of apps accessible by a user, not including personal apps.
      #
      # @param user_id [Integer] Id of the user
      #
      # @return [Array] the apps of the user identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/get-apps-for-user Get Apps for a User documentation}
      def get_user_apps(user_id)
        clean_error
        prepare_token

        begin
          options = {
            model: OneLogin::Api::Models::App,
            headers: request_headers
          }

          return Cursor.new(get_url(GET_APPS_FOR_USER_URL, user_id), options)

        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets a list of role IDs that have been assigned to a user.
      #
      # @param user_id [Integer] Id of the user
      #
      # @return [Array] the role ids of the user identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/get-roles-for-user Get Roles for a User documentation}
      def get_user_roles(user_id)
        clean_error
        prepare_token

        begin

          url = get_url(GET_ROLES_FOR_USER_URL, user_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          role_ids = []
          if response.code == 200
            json_data = JSON.parse(response.body)
            role_ids = json_data['data'][0] if json_data && json_data['data']
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end

          return role_ids
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets a list of all custom attribute fields (also known as custom user fields) that have been defined for OL account.
      #
      # @return [Array] the custom attributes of the account
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/get-custom-attributes Get Custom Attributes documentation}
      def get_custom_attributes
        clean_error
        prepare_token

        begin

          url = get_url(GET_CUSTOM_ATTRIBUTES_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          custom_attributes = []
          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              custom_attributes = json_data['data'][0]
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end

          return custom_attributes
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Creates an user
      #
      # @param user_params [Hash] User data (firstname, lastname, email, username, company,
      #                                      department, directory_id, distinguished_name,
      #                                      external_id, group_id, invalid_login_attempts,
      #                                      locale_code, manager_ad_id, member_of,
      #                                      openid_name, phone, samaccountname, title,
      #                                      userprincipalname)
      #
      # @return [User] the created user
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/create-user Create User documentation}
      def create_user(user_params)
        clean_error
        prepare_token

        begin

          url = get_url(CREATE_USER_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: user_params.to_json
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::User.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Updates an user
      #
      # @param user_id [Integer] Id of the user
      # @param user_params [Hash] User data (firstname, lastname, email, username, company,
      #                                      department, directory_id, distinguished_name,
      #                                      external_id, group_id, invalid_login_attempts,
      #                                      locale_code, manager_ad_id, member_of,
      #                                      openid_name, phone, samaccountname, title,
      #                                      userprincipalname)
      #
      # @return [User] the modified user
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/update-user Update User by ID documentation}
      def update_user(user_id, user_params)
        clean_error
        prepare_token

        begin

          url = get_url(UPDATE_USER_URL, user_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: user_params.to_json
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::User.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Assigns Roles to User
      #
      # @param user_id [Integer] Id of the user
      # @param role_ids [Array] List of role ids to be added
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/assign-role-to-user Assign Role to User documentation}
      def assign_role_to_user(user_id, role_ids)
        clean_error
        prepare_token

        begin

          url = get_url(ADD_ROLE_TO_USER_URL, user_id)

          authorization = get_authorization

          data = {
            'role_id_array' => role_ids
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Removes Role from User
      #
      # @param user_id [Integer] Id of the user
      # @param role_ids [Array] List of role ids to be removed
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/remove-role-from-user Remove Role from User documentation}
      def remove_role_from_user(user_id, role_ids)
        clean_error
        prepare_token

        begin

          url = get_url(DELETE_ROLE_TO_USER_URL, user_id)

          authorization = get_authorization

          data = {
            'role_id_array' => role_ids
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Sets Password by ID Using Cleartext
      #
      # @param user_id [Integer] Id of the user
      # @param password [String] Set to the password value using cleartext.
      # @param password_confirmation [String] Ensure that this value matches the password value exactly.
      # @validate_policy [Boolean] Force validation against assigned OneLogin user password policy
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/set-password-in-cleartext Set Password by ID Using Cleartext documentation}
      def set_password_using_clear_text(user_id, password, password_confirmation, validate_policy=false)
        clean_error
        prepare_token

        begin

          url = get_url(SET_PW_CLEARTEXT, user_id)

          authorization = get_authorization

          data = {
            'password' => password,
            'password_confirmation' => password_confirmation,
            'validate_policy' => validate_policy
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Set Password by ID Using Salt and SHA-256
      #
      # @param user_id [Integer] Id of the user
      # @param password [String] Set to the password value using cleartext.
      # @param password_confirmation [String] Ensure that this value matches the password value exactly.
      # @param password_algorithm [String] Set to salt+sha256.
      # @param password_salt [String] (Optional) To provide your own salt value.
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/set-password-using-sha-256 Set Password by ID Using Salt and SHA-256 documentation}
      def set_password_using_hash_salt(user_id, password, password_confirmation, password_algorithm, password_salt=nil)
        clean_error
        prepare_token

        begin

          url = get_url(SET_PW_SALT, user_id)

          authorization = get_authorization

          data = {
            'password' => password,
            'password_confirmation' => password_confirmation,
            'password_algorithm' => password_algorithm
          }

          unless password_salt.nil?
            data['password_salt'] = password_salt
          end

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Set Custom Attribute Value
      #
      # @param user_id [Integer] Id of the user
      # @param custom_attributes [Hash] Provide one or more key value pairs composed of the custom attribute field shortname and the value that you want to set the field to.
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/set-custom-attribute Set Custom Attribute Value documentation}
      def set_custom_attribute_to_user(user_id, custom_attributes)
        clean_error
        prepare_token

        begin

          url = get_url(SET_CUSTOM_ATTRIBUTE_TO_USER_URL, user_id)

          authorization = get_authorization

          data = {
            'custom_attributes' => custom_attributes
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Log a user out of any and all sessions.
      #
      # @param user_id [Integer] Id of the user to be logged out
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/log-user-out Log User Out documentation}
      def log_user_out(user_id)
        clean_error
        prepare_token

        begin

          url = get_url(LOG_USER_OUT_URL, user_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Use this call to lock a user's account based on the policy assigned to
      # the user, for a specific time you define in the request, or until you
      # unlock it.
      #
      # @param user_id [Integer] Id of the user to be locked
      # @param minutes [Integer] Set to the number of minutes for which you want to lock the user account. (0 to delegate on policy)
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/lock-user-account Lock User Account documentation}
      def lock_user(user_id, minutes)
        clean_error
        prepare_token

        begin

          url = get_url(LOCK_USER_URL, user_id)

          authorization = get_authorization

          data = {
            'locked_until' => minutes
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.put(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Deletes an user
      #
      # @param user_id [Integer] Id of the user to be logged out
      #
      # @return [Boolean] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/delete-user Delete User by ID documentation}
      def delete_user(user_id)
        clean_error
        prepare_token

        begin

          url = get_url(DELETE_USER_URL, user_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.delete(
            url,
            headers: headers
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Generates a session login token in scenarios in which MFA may or may not be required.
      # A session login token expires two minutes after creation.
      #
      # @param query_params [Hash] Query Parameters (username_or_email, password, subdomain, return_to_url,
      #                                              ip_address, browser_id)
      # @param allowed_origin [String] Custom-Allowed-Origin-Header. Required for CORS requests only.
      #                                Set to the Origin URI from which you are allowed to send a request
      #                                using CORS.
      #
      # @return [SessionTokenInfo|SessionTokenMFAInfo] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/create-session-login-token Create Session Login Token documentation}
      def create_session_login_token(query_params, allowed_origin='')
        clean_error
        prepare_token

        begin

          url = get_url(SESSION_LOGIN_TOKEN_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          unless allowed_origin.nil? || allowed_origin.empty?
            headers['Custom-Allowed-Origin-Header-1'] = allowed_origin
          end

          if query_params.nil? || !query_params.has_key?('username_or_email') || !query_params.has_key?('password') || !query_params.has_key?('subdomain')
            raise "username_or_email, password and subdomain are required parameters"
          end

          response = HTTParty.post(
            url,
            headers: headers,
            body: query_params.to_json
          )

          if response.code == 200
            return handle_session_token_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Verify a one-time password (OTP) value provided for multi-factor authentication (MFA).
      #
      # @param device_id [String] Provide the MFA device_id you are submitting for verification.
      # @param state_token [String] Provide the state_token associated with the MFA device_id you are submitting for verification.
      # @param otp_token [String] (Optional) Provide the OTP value for the MFA factor you are submitting for verification.
      #
      # @return [SessionTokenInfo] if the action succeed
      #
      # @see {https://developers.onelogin.com/api-docs/1/users/verify-factor Verify Factor documentation}
      def get_session_token_verified(device_id, state_token, otp_token=nil)
        clean_error
        prepare_token

        begin

          url = get_url(GET_TOKEN_VERIFY_FACTOR)

          authorization = get_authorization

          data = {
            'device_id'=> device_id.to_s,
            'state_token'=> state_token
          }

          unless otp_token.nil? || otp_token.empty?
            data['otp_token'] = otp_token
          end

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_session_token_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      ################
      # Role Methods #
      ################

      # Gets a list of Role resources. (if no limit provided, by default get 50 elements)
      #
      # @param params [Hash] Parameters to filter the result of the list
      #
      # @return [Array] list of Role objects
      #
      # @see {https://developers.onelogin.com/api-docs/1/roles/get-roles Get Roles documentation}
      def get_roles(params={})
        clean_error
        prepare_token

        limit = params[:limit] || 50
        params.delete(:limit) if limit > 50

        begin

          url = get_url(GET_ROLES_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          roles = []
          response = nil
          after_cursor = nil
          while response.nil? || roles.length > limit || !after_cursor.nil?
            response = HTTParty.get(
              url,
              headers: headers,
              query: params
            )
            if response.code == 200
              json_data = JSON.parse(response.body)
              if json_data && json_data['data']
                json_data['data'].each do |role_data|
                  if roles.length < limit
                    roles << OneLogin::Api::Models::Role.new(role_data)
                  else
                    return roles
                  end
                end
              end

              after_cursor = get_after_cursor(response)
              unless after_cursor.nil?
                if params.nil?
                  params = {}
                end
                params['after_cursor'] = after_cursor
              end
            else
              @error = response.code.to_s
              @error_description = extract_error_message_from_response(response)
              break
            end
          end

          return roles
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets Role by ID.
      #
      # @param role_id [Integer] Id of the Role
      #
      # @return [Role] the role identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/roles/get-role-by-id Get Role by ID documentation}
      def get_role(role_id)
        clean_error
        prepare_token

        begin

          url = get_url(GET_ROLE_URL, role_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::Role.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      #################
      # Event Methods #
      #################

      # List of all OneLogin event types available to the Events API.
      #
      # @return [Array] the list of event type
      #
      # @see {https://developers.onelogin.com/api-docs/1/events/event-types Get Event Types documentation}
      def get_event_types
        clean_error
        prepare_token

        begin
        options = {
          model: OneLogin::Api::Models::EventType,
          headers: request_headers
        }

        return Cursor.new(get_url(GET_EVENT_TYPES_URL), options)

        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets a list of Event resources. (if no limit provided, by default get 50 elements)
      #
      # @param params [Hash] Parameters to filter the result of the list
      #
      # @return [Array] list of Event objects
      #
      # @see {https://developers.onelogin.com/api-docs/1/events/get-events Get Events documentation}
      def get_events(params={})
        clean_error
        prepare_token

        begin
        options = {
          model: OneLogin::Api::Models::Event,
          headers: request_headers,
          params: params
        }

        return Cursor.new(get_url(GET_EVENTS_URL), options)

        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets Event by ID.
      #
      # @param event_id [Integer] Id of the Event
      #
      # @return [Event] the event identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/events/get-event-by-id Get Event by ID documentation}
      def get_event(event_id)
        clean_error
        prepare_token

        begin

          url = get_url(GET_EVENT_URL, event_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::Event.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Create an event in the OneLogin event log.
      #
      # @param event_params [Hash] Event data (event_type_id, account_id, actor_system,
      #                                        actor_user_id, actor_user_name, app_id,
      #                                        assuming_acting_user_id, custom_message,
      #                                        directory_sync_run_id, group_id, group_name,
      #                                        ipaddr, otp_device_id, otp_device_name,
      #                                        policy_id, policy_name, role_id, role_name,
      #                                        user_id, user_name)
      #
      # @return [Boolean] the result of the operation
      #
      # @see {https://developers.onelogin.com/api-docs/1/events/create-event Create Event documentation}
      def create_event(event_params)
        clean_error
        prepare_token

        begin

          url = get_url(CREATE_EVENT_URL)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: event_params.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      #################
      # Group Methods #
      #################

      # Gets a list of Group resources (element of groups limited with the limit parameter).
      #
      # @return [Array] the list of groups
      #
      # @see {https://developers.onelogin.com/api-docs/1/groups/get-groups Get Groups documentation}
      def get_groups(params = {})
        clean_error
        prepare_token

        begin
        options = {
          model: OneLogin::Api::Models::Group,
          headers: request_headers
        }

        return Cursor.new(get_url(GET_GROUPS_URL), options)

        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Gets Group by ID.
      #
      # @param group_id [Integer] Id of the Group
      #
      # @return [Group] the group identified by the id
      #
      # @see {https://developers.onelogin.com/api-docs/1/groups/get-group-by-id Get Group by ID documentation}
      def get_group(group_id)
        clean_error
        prepare_token

        begin

          url = get_url(GET_GROUP_URL, group_id)

          authorization = get_authorization

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return OneLogin::Api::Models::Group.new(json_data['data'][0])
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      ##########################
      # SAML Assertion Methods #
      ##########################

      # Generates a SAML Assertion.
      #
      # @param username_or_email [String] username or email of the OneLogin user accessing the app
      # @param password [String] Password of the OneLogin user accessing the app
      # @param app_id [String] App ID of the app for which you want to generate a SAML token
      # @param subdomain [String] subdomain of the OneLogin account related to the user/app
      # @param ip_address [String] (Optional) whitelisted IP address that needs to be bypassed (some MFA scenarios)
      #
      # @return [SAMLEndpointResponse] object with an encoded SAMLResponse
      #
      # @see {https://developers.onelogin.com/api-docs/1/saml-assertions/generate-saml-assertion Generate SAML Assertion documentation}
      def get_saml_assertion(username_or_email, password, app_id, subdomain, ip_address=nil)
        clean_error
        prepare_token

        begin

          url = get_url(GET_SAML_ASSERTION_URL)

          authorization = get_authorization

          data = {
            'username_or_email'=> username_or_email,
            'password'=> password,
            'app_id'=> app_id,
            'subdomain'=> subdomain,
          }

          unless ip_address.nil? || ip_address.empty?
            data['ip_address'] = ip_address
          end

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_saml_endpoint_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Verify a one-time password (OTP) value provided for a second factor when multi-factor authentication (MFA) is required for SAML authentication.
      #
      # @param app_id [String] App ID of the app for which you want to generate a SAML token
      # @param devide_id [String] Provide the MFA device_id you are submitting for verification.
      # @param state_token [String] Provide the state_token associated with the MFA device_id you are submitting for verification.
      # @param otp_token [String] (Optional) Provide the OTP value for the MFA factor you are submitting for verification.
      # @param url_endpoint [String] (Optional) Specify an url where return the response.
      #
      # @return [SAMLEndpointResponse] object with an encoded SAMLResponse
      #
      # @see {https://developers.onelogin.com/api-docs/1/saml-assertions/verify-factor Verify Factor documentation}
      def get_saml_assertion_verifying(app_id, device_id, state_token, otp_token=nil, url_endpoint=nil)
        clean_error
        prepare_token

        begin

          if url_endpoint.nil? || url_endpoint.empty?
            url = get_url(GET_SAML_VERIFY_FACTOR)
          else
            url = url_endpoint
          end

          authorization = get_authorization

          data = {
            'app_id'=> app_id,
            'device_id'=> device_id.to_s,
            'state_token'=> state_token
          }

          unless otp_token.nil? || otp_token.empty?
            data['otp_token'] = otp_token
          end

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_saml_endpoint_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      ########################
      # Invite Links Methods #
      ########################

      # Generates an invite link for a user that you have already created in your OneLogin account.
      #
      # @param email [String] Set to the email address of the user that you want to generate an invite link for.
      #
      # @return [String] the invitation link
      #
      # @see {https://developers.onelogin.com/api-docs/1/invite-links/generate-invite-link Generate Invite Link documentation}
      def generate_invite_link(email)
        clean_error
        prepare_token

        begin

          url = get_url(GENERATE_INVITE_LINK_URL)

          authorization = get_authorization

          data = {
            'email'=> email
          }

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            json_data = JSON.parse(response.body)
            if json_data && json_data['data']
              return json_data['data'][0]
            end
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

      # Sends an invite link to a user that you have already created in your OneLogin account.
      #
      # @param email [String] Set to the email address of the user that you want to send an invite link for.
      # @param personal_email [String] (Optional) If you want to send the invite email to an email other than the
      #                                one provided in email, provide it here. The invite link will be
      #                                sent to this address instead.
      #
      # @return [String] the result of the operation
      #
      # @see {https://developers.onelogin.com/api-docs/1/invite-links/send-invite-link Send Invite Link documentation}
      def send_invite_link(email, personal_email=nil)
        clean_error
        prepare_token

        begin

          url = get_url(SEND_INVITE_LINK_URL)

          authorization = get_authorization

          data = {
            'email'=> email
          }

          unless personal_email.nil? || personal_email.empty?
            data['personal_email'] = personal_email
          end

          headers = {
            'Authorization' => authorization,
            'Content-Type' => 'application/json',
            'User-Agent' => @user_agent
          }

          response = HTTParty.post(
            url,
            headers: headers,
            body: data.to_json
          )

          if response.code == 200
            return handle_operation_response(response)
          else
            @error = response.code.to_s
            @error_description = extract_error_message_from_response(response)
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        false
      end

      # Lists apps accessible by a OneLogin user.
      #
      # @param token [String] Provide your embedding token.
      # @param email [String] Provide the email of the user for which you want to return a list of embeddable apps.
      #
      # @return [Array] the embed apps
      #
      # @see {https://developers.onelogin.com/api-docs/1/embed-apps/get-apps-to-embed-for-a-user Get Apps to Embed for a User documentation}
      def get_embed_apps(token, email)
        clean_error

        begin

          url = EMBED_APP_URL

          data = {
            'token'=> token,
            'email'=> email
          }

          headers = {
            'User-Agent' => @user_agent
          }

          response = HTTParty.get(
            url,
            headers: headers,
            query: data
          )

          if response.code == 200 && !(response.body.nil? || response.body.empty?)
            return retrieve_apps_from_xml(response.body)
          else
            @error = response.code.to_s
            unless response.body.nil? || response.body.empty?
              @error_description = response.body
            end
          end
        rescue Exception => e
          @error = '500'
          @error_description = e.message
        end

        nil
      end

    end
  end
end
