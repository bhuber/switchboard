class List < ActiveRecord::Base

  validates_format_of :name, :with => /^\S+$/, :message => "List name cannot contain spaces"
  validates_uniqueness_of :name
  has_many :list_memberships
  has_many :phone_numbers, :through => :list_memberships
  belongs_to :admin, :class_name => 'PhoneNumber'
 
  has_many :messages, :order => "created_at DESC"

  ## 
  ## TODO: decide if these receive objects or strings or are flexible?
  ## for now: take objects

  def add_phone_number(phone_number)
    return if self.has_number?(phone_number)
    puts "adding number: " + phone_number.number 
    self.save
    self.list_memberships.create! :phone_number_id => phone_number.id
    if(self.use_welcome_message?)
      puts "has welcome message, and creating outgoing message"
      welcome_message = self.custom_welcome_message
      create_outgoing_message( phone_number, welcome_message )
    end 
  end

  def remove_phone_number(phone_number)
    return unless self.has_number?(phone_number)
    self.list_memberships.find_by_phone_number_id(phone_number.id).destroy
  end

  def has_number?(phone_number)
    self.list_memberships.exists?(:phone_number_id => phone_number.id)
  end

  def phone_numbers
    numbers =  []
    self.list_memberships.each do |mem|
      numbers << mem.phone_number
    end
    return numbers
  end


  def most_recent_message
    return ( self.messages.count > 0 ? self.messages[0] : nil )
  end

  def most_recent_messages( count )
    return self.messages.find( :all, :order => "created_at DESC", :limit => count )
  end

  def most_recent_message_from_user(user)
    self.messages.find( :all, :conditions => { :sender_id => user.id }, :order => "created_at DESC", :limit => 1 )
  end

  def create_email_message(num)
    message = EmailMessage.new
    message.to = num.number + "@" + num.provider_email
    message.from = self.name + "@mmptext.info"
    return message
  end

  def create_twilio_message(num)
    message = TwilioMessage.new
    message.to = num.number
    return message
  end

  def create_outgoing_message(num, body)
    # once there are other external gateways, or not all phone numbers support the commercial gateway
    # this gets more complicated 

    if ( num.can_receive_email? and self.allow_email_gateway? and
      ( (! self.allow_commercial_gateway?) or self.prefer_email ))
      message = create_email_message(num)
    elsif (self.allow_commercial_gateway? and num.can_receive_gateway?)
      message = create_twilio_message(num)
    else 
      raise "list & subscriber settings make sending message impossible for num: " + num.number
    end

    message.body = body

    message_state = MessageState.find_by_name("outgoing")
    message_state.messages.push(message)
    message_state.save!
  end

  def name=(value)
    self[:name] = value.upcase!
  end

  ### these methods make editing lists easier
  def welcome_message
    self.custom_welcome_message || self.default_welcome_message
  end
  
  def welcome_message=(message)
    self.update_attribute('custom_welcome_message', message)
  end

  def list_type
    self.all_users_can_send_messages ? 'discussion' : 'announcement'
  end

  def list_type=(type)
    self.update_attribute('all_users_can_send_messages', (type == 'discussion'))
  end

  def join_policy
    self.open_membership ? 'open' : 'closed'
  end

  def join_policy=(policy)
    self.update_attribute("open_membership", (policy == 'open'))
  end
  ### /these methods make editing lists easier

  def handle_send_action(message, num)
    message.list = self 
    message.sender = num.user
    message.save
    if (message.from_web? or self.all_users_can_send_messages? or @admin == num)
      self.phone_numbers.each do |phone_number|
        body = '[' + self[:name] + '] ' + message.tokens.join(' ')
        puts "sending message: " + body + ", to: " + phone_number.number
        self.create_outgoing_message(phone_number, body)
      end
    else
      if (list.admin != nil)
        admin_msg = '[' + self[:name] + ' from '
        admin_msg +=  num.number.to_s

        if ( num.user != nil and (! num.user.first_name.blank?) )
          admin_msg += "/ " + num.user.first_name.to_s + " " + num.user.last_name.to_s
        end

        admin_msg += '] '
        admin_msg += tokens.join(' ')
        self.create_outgoing_message(list.admin, admin_msg )
      end
    end
  end

  def handle_join_message(message,  tokens, num)
    if self.has_number?(num)
      self.create_outgoing_message( num, "It seems like you are trying to join the list '" + self[:name] + "', but you are already a member.")
    else
      if (self.open_membership)
        message.list = self
        if (num.user == nil)
          puts "adding user for num: " + num.number
          num.user = User.create(:password => 'abcdef981', :password_confirmation => 'abcdef981')
          num.save
          num.user.save
        end

        self.add_phone_number(num)

        message.sender = num.user
        message.save
        self.save 
      else ## not list.open_membership
        self.create_outgoing_message( num, "I'm sorry, but this list is configured as a private list and only the administrator can add new members.")
      end
    end
  end


  protected

    def default_welcome_message
      "Welcome to the '#{self.name}' list! To unsbuscribe, text '....'. To receive help, text '....'" 
    end

end
