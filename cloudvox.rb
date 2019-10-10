class Channel::Driver::Sms::Cloudvox
  NAME = 'sms/cloudvox'.freeze

  def fetchable?(_channel)
    false
  end

  def send(options, attr, _notification = false)
    Rails.logger.info "Sending SMS to recipient #{attr[:recipient]}"

    return true if Setting.get('import_mode')

    Rails.logger.info "Backend sending Cloudvox SMS to #{attr[:recipient]}"
    begin
      params = build_params(options, attr)

      if Setting.get('developer_mode') != true
        response = Faraday.post(options[:gateway], params).body
        raise response if !response.match?('Message accepted')
      end

      true
    rescue => e
      Rails.logger.debug "Cloudvox error: #{e.inspect}"
      raise e
    end
  end

  def process(_options, attr, channel)
    Rails.logger.info "Receiving SMS from recipient #{attr[:From]}"

    # prevent already created articles
    if Ticket::Article.find_by(message_id: attr[:SmsMessageSid])
      return ['application/json; charset=UTF-8;', { status: 'processed', ticket_id: ''}.to_json]
    end

    # find sender
    user = User.where(mobile: attr[:From]).order(:updated_at).first
    if !user
      _from_comment, preferences = Cti::CallerId.get_comment_preferences(attr[:From], 'from')
      if preferences && preferences['from'] && preferences['from'][0]
        if preferences['from'][0]['level'] == 'known' && preferences['from'][0]['object'] == 'User'
          user = User.find_by(id: preferences['from'][0]['o_id'])
        end
      end
    end
    if !user
      user = User.create!(
        firstname: attr[:From],
        mobile:    attr[:From],
      )
    end

    UserInfo.current_user_id = user.id

    # find ticket
    article_type_sms = Ticket::Article::Type.find_by(name: 'sms')
    state_ids = Ticket::State.where(name: %w[closed merged removed]).pluck(:id)
    ticket = Ticket.where(customer_id: user.id, create_article_type_id: article_type_sms.id).where.not(state_id: state_ids).order(:updated_at).first
    ticket_action = 'created'

    if ticket
      ticket_action = 'updated'
      new_state = Ticket::State.find_by(default_create: true)
      if ticket.state_id != new_state.id
        ticket.state = Ticket::State.find_by(default_follow_up: true)
        ticket.save!
      end
    else
      if channel.group_id.blank?
        raise Exceptions::UnprocessableEntity, 'Group needed in channel definition!'
      end

      group = Group.find_by(id: channel.group_id)
      if !group
        raise Exceptions::UnprocessableEntity, 'Group is invalid!'
      end

      title = attr[:Body]
      if title.length > 40
        title = "#{title[0, 40]}..."
      end
      ticket = Ticket.new(
        group_id:    channel.group_id,
        title:       title,
        state_id:    Ticket::State.find_by(default_create: true).id,
        priority_id: Ticket::Priority.find_by(default_create: true).id,
        customer_id: user.id,
        preferences: {
          channel_id: channel.id,
          sms:        {
            AccountSid: attr['AccountSid'],
            From:       attr['From'],
            To:         attr['To'],
          }
        }
      )
      ticket.save!
    end

    Ticket::Article.create!(
      ticket_id:    ticket.id,
      type:         article_type_sms,
      sender:       Ticket::Article::Sender.find_by(name: 'Customer'),
      body:         attr[:Body],
      from:         attr[:From],
      to:           attr[:To],
      message_id:   attr[:SmsMessageSid],
      content_type: 'text/plain',
      preferences:  {
        channel_id: channel.id,
        sms:        {
          AccountSid: attr['AccountSid'],
          From:       attr['From'],
          To:         attr['To'],
        }
      }
    )

    ['application/json; charset=UTF-8;', { status: ticket_action, ticket_id: ticket.id }.to_json]
  end

  def self.definition
    {
      name:         'cloudvox',
      adapter:      'sms/cloudvox',
      account:      [
        { name: 'options::gateway', display: 'Gateway', tag: 'input', type: 'text', limit: 200, null: false, placeholder: 'https://sms.cloudvox.eu/messages/send_api', default: 'https://sms.cloudvox.eu/messages/send_api' },
        { name: 'options::webhook_token', display: 'Webhook Token', tag: 'input', type: 'text', limit: 200, null: false, default: Digest::MD5.hexdigest(rand(999_999_999_999).to_s), disabled: true, readonly: true },
        { name: 'options::token', display: 'Cloudvox SMS API Key', tag: 'input', type: 'text', limit: 200, null: false },
        { name: 'options::sender', display: 'Sender', tag: 'input', type: 'text', limit: 200, null: false, placeholder: '+491710000000' },
        { name: 'group_id', display: 'Destination Group', tag: 'select', null: false, relation: 'Group', nulloption: true, filter: { active: true } },
      ],
      notification: [
        { name: 'options::gateway', display: 'Gateway', tag: 'input', type: 'text', limit: 200, null: false, placeholder: 'https://sms.cloudvox.eu/messages/send_api', default: 'https://sms.cloudvox.eu/messages/send_api' },
        { name: 'options::token', display: 'Cloudvox SMS API Key', tag: 'input', type: 'text', limit: 200, null: false },
        { name: 'options::sender', display: 'Sender', tag: 'input', type: 'text', limit: 200, null: false, placeholder: '+491710000000' },
      ],
    }
  end

  private

  def build_params(options, attr)
    {
      api_key:      options[:token],
      message:      attr[:message],
      long_message: 'y',
      recipient:    attr[:recipient].remove(/\D/),
      sender:       options[:sender].remove(/\D/)
    }
  end
end
