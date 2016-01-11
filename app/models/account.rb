class Account < ActiveRecord::Base
  has_secure_password

  store :metadata, accessors: [:auth_mobile]

  attr_accessor :current_password

  validates :nickname, presence: true, uniqueness: { case_sensitive: false }, length: { within: 3..20, too_short: '太短了，最少3位', too_long: "太长了，最多20位" }
  validates :email, email: true, presence: true#, uniqueness: { case_sensitive: false }
  validates :mobile, presence: true, format: { with: /^\d{11}$/, message: '手机格式不正确' }
  validates :password, presence: { message: '不能为空', on: :create }, length: { within: 6..20, too_short: '太短了，最少6位', too_long: "太长了，最多20位" }, allow_blank: true
  validates_confirmation_of :password, message: '确认不一致'

  enum_attr :account_type, :in => [
    ['normal_account', 1, '正式帐号'],
    ['trial_account',  2, '试用帐号'],
    ['free_account',  3, '免费帐号'],
  ]

  enum_attr :status, :in => [
    ['pending', 0, '待审核'],
    ['active',  1, '正常'],
    ['froze',  -1, '已冻结']
  ]

  belongs_to :account_footer

  has_one :print
  has_one :account_password
  has_one :pay_account
  has_many :payments

  has_one :site
  has_many :sites
  has_many :sms_expenses
  has_many :sms_orders
  has_many :feedbacks

  def self.current
    Thread.current[:account]
  end

  def self.current=(account)
    Thread.current[:account] = account
  end

  def self.authenticated(nickname, password)
    #where("lower(nickname) = ?", nickname.to_s.downcase).first.try(:authenticate, password)
    where("lower(nickname) LIKE ?", nickname.to_s.downcase).first.try(:authenticate, password)
  end

  # 商户发送短信 account.send_message("13795288852", "Hello World", "电商")
  # 参数 operation in (电商,餐饮, 酒店)
  def send_message(mobiles, content, operation, is_free = false)
    @errors = []
    @errors << "手机号码不能为空" if mobiles.blank?

    phones = mobiles.split(',').map(&:to_s).map{|m| m.gsub(' ', '')}.compact.uniq
    unless is_free
      @errors << "商户未开启短信通知服务" unless self.is_open_sms
    end

    phones.map{|m| @errors << "手机号码格式不正确" unless m.to_s =~ /^\d+$/ }
    @errors << "短信内容不能为空" if content.blank?

    if @errors.blank?
      if is_free
        mass_send_message(phones, content)
      elsif free_sms_count > 0
        message_id = mass_send_message(phones, content)
        send_success = message_id > 1 || message_id < -10000000
        sms_status = send_success ? 1 : message_id
        update_attribute(:free_sms_count, free_sms_count - phones.count) if send_success
      elsif pay_sms_count > 0
        message_id = mass_send_message(phones, content)
        send_success = message_id > 1 || message_id < -10000000
        sms_status = send_success ? 1 : message_id
        update_attribute(:pay_sms, pay_sms_count - phones.count) if send_success
      else
        @errors << "商户 account_id #{self.id} 短信套餐余额不足"
        sms_status = -99
      end
      operation_id = SmsExpense.get_operation_id_by_operation_name(operation)
      phones.each{|phone| SmsExpense.create(date: Date.today, account_id: self.id, phone: phone, content: content, operation_id: operation_id, status: sms_status)} if !is_free
    end
    {errors: @errors, message_id: message_id}
  rescue => e
    Rails.logger.info "account send_message is error: #{e}"
    e.backtrace.each { |error_msg| Rails.logger.info error_msg }
    {errors: ["发送短信出错：#{e.message}"], message_id: 0}
  end

  def send_system_message(options = {}, smm = nil)
    smm = SystemMessageModule.where(module_id: options[:module_id]).first unless smm
    sms = SystemMessageSetting.where(account_id: options[:account_id], system_message_module_id: smm.id).first_or_initialize(account_id: options[:account_id], system_message_module_id: smm.id)
    if sms.is_open
      sms.system_messages << SystemMessage.new(account_id: options[:account_id], content: options[:content], system_message_module_id: smm.id)
      sms.save!
    else
      sms.view_remind_music
    end
  end

  def update_all_system_messages
    if system_messages.unread.update_all(is_read: true) > 0
      uri = URI.parse("http://#{FAYE_HOST}/faye")
      Net::HTTP.post_form(uri, message: {channel: "/system_messages/change/#{id}", data: {operate: 'delete_all'}}.to_json)
    end
  end

  def find_or_generate_auth_token(encrypt = true)
    update_attributes(token: SecureRandom.urlsafe_base64(60)) unless token.present?
    encrypt ? Des.encrypt(token) : token
  end

  def app_footer
    # AccountFooter.find_by_id(account_footer_id) || AccountFooter.default_footer
    AccountFooter.default_footer
  end

  def update_sign_in_attrs_with(sign_in_ip)
    update_attributes(
      sign_in_count: sign_in_count.next,
      last_sign_in_at: current_sign_in_at,
      last_sign_in_ip: current_sign_in_ip,
      current_sign_in_at: Time.now,
      current_sign_in_ip: sign_in_ip
    )
  end

  def open_sms!
    update_attributes!(is_open_sms: true)
  end

  def close_sms!
    update_attributes!(is_open_sms: false)
  end

  def expired?
    expired_at.nil? || expired_at < Time.now
  end

  def can_pay?
    payment_settings.present?
  end

  def can_recharge?
    enabled_payment_setting_types.count > 0
  end

  # TODO
  def has_privilege_for?(id)
    true
  end

  def need_auth_mobile?
    auth_mobile.to_i != 1
  end

  def enabled_payment_settings
    payment_settings.enabled
  end

  def enabled_payment_types
    payment_settings.enabled.map(&:payment_type).map(&:id_name)
  end

  def enabled_payment_setting_types
    @enabled_payment_setting_types ||= enabled_payment_settings.pluck(:type)
  end

  def account_password_correct?( password )
    password.present? && password == account_password.try(:password_digest)
  end

  def buy_sms_totality
    self.sms_orders.buy.where(status: [SmsOrder::SUCCEED, SmsOrder::F_DELETE]).collect(&:plan_sms).sum
  end

  def giv_sms_totality
    self.sms_orders.giv.collect(&:plan_sms_count).sum
  end

  def usable_sms
    self.pay_sms_count.to_i + self.free_sms_count.to_i
  end

  def sms_expenses_count(date, operation_id = nil)
    condtions = {date: date, status: 1}
    condtions.merge!(operation_id: operation_id) if  operation_id
    self.sms_expenses.where(condtions).count
  end

  def send_password_reset
    generate_token(:password_reset_token)
    self.password_reset_sent_at = Time.zone.now
    save!
    AccountMailer.password_reset(self).deliver
  end

  def generate_token(column)
    begin
      self[column] = SecureRandom.urlsafe_base64
    end while Account.exists?(column => self[column])
  end

  private

  def do_send_message(phone, content)
    sms_service = SmsService.new
    sms_service.singleSend(phone, content)
    # result =  rand  > 0.3 && 101812252025653392 || -4

    # 短信发送失败，添加错误信息
    @errors << sms_service.error_message if sms_service.error?
    sms_service.result
  end

  def mass_send_message(phones, content)
    sms_service = SmsService.new
    sms_service.batchSend(phones, content)
    # 短信发送失败，添加错误信息
    @errors << sms_service.error_message if sms_service.error?
    sms_service.result
  end

end