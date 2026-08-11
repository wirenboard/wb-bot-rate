# frozen_string_literal: true

RSpec.describe WbBotRate::Relief do
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:human) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:bot) { Fabricate(:user, trust_level: TrustLevel[4]) }

  let(:limiter) { instance_double(RateLimiter) }

  def post_in(topic, user = author)
    post = Fabricate(:post, topic: topic, user: user)
    allow(post).to receive(:default_rate_limiter).and_return(limiter)
    post
  end

  def bot_pm(user = author)
    Fabricate(:private_message_topic, user: user, topic_allowed_users: [
      Fabricate.build(:topic_allowed_user, user: user),
      Fabricate.build(:topic_allowed_user, user: bot),
    ])
  end

  def cap_ttl(post)
    Discourse.redis.ttl("wb-bot-rate:rollbacks:#{post.topic_id}:#{post.user_id}")
  end

  def human_pm
    Fabricate(:private_message_topic, user: author, topic_allowed_users: [
      Fabricate.build(:topic_allowed_user, user: author),
      Fabricate.build(:topic_allowed_user, user: human),
    ])
  end

  before do
    SiteSetting.wb_bot_rate_enabled = true
    SiteSetting.wb_bot_rate_max_rollbacks = 2
    SiteSetting.rate_limit_create_post = 5

    stub_const("DiscourseAi::AiBot::EntryPoint", Class.new) if !defined?(::DiscourseAi::AiBot::EntryPoint)
    allow(SiteSetting).to receive(:discourse_ai_enabled).and_return(true)
    allow(::DiscourseAi::AiBot::EntryPoint).to receive(:all_bot_ids).and_return([bot.id])
  end

  it "откатывает ограничитель в личной теме с ботом" do
    expect(limiter).to receive(:rollback!).once
    described_class.new(post_in(bot_pm)).apply!
  end

  it "не трогает личную переписку между людьми" do
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(human_pm)).apply!
  end

  it "не трогает обычную форумную тему" do
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(Fabricate(:topic))).apply!
  end

  it "молчит, когда плагин выключен" do
    SiteSetting.wb_bot_rate_enabled = false
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(bot_pm)).apply!
  end

  it "молчит, когда потолок равен нулю" do
    SiteSetting.wb_bot_rate_max_rollbacks = 0
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(bot_pm)).apply!
  end

  it "не даёт больше отката, чем разрешает потолок" do
    topic = bot_pm
    expect(limiter).to receive(:rollback!).twice
    3.times { described_class.new(post_in(topic)).apply! }
  end

  it "считает потолок отдельно по каждой теме" do
    expect(limiter).to receive(:rollback!).exactly(4).times
    [bot_pm, bot_pm].each { |t| 3.times { described_class.new(post_in(t)).apply! } }
  end

  it "не трогает персонал — у него ограничителя и так нет" do
    author.update!(moderator: true)
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(bot_pm)).apply!
  end

  it "не откатывает пост, созданный со skip_validations" do
    post = post_in(bot_pm)
    post.skip_validation = true
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post).apply!
  end

  it "молчит, когда discourse-ai выключен" do
    allow(SiteSetting).to receive(:discourse_ai_enabled).and_return(false)
    expect(limiter).not_to receive(:rollback!)
    described_class.new(post_in(bot_pm)).apply!
  end

  # Окно счётчика откатов обязано совпадать с окном самого ограничителя —
  # той же развилкой, что в RateLimiter::OnCreateRecord#default_rate_limiter.
  # Иначе потолок считался бы не за то время, за которое действует лимит.
  describe "длина окна" do
    fab!(:newbie) { Fabricate(:user, trust_level: TrustLevel[0]) }

    before do
      SiteSetting.rate_limit_create_post = 5
      SiteSetting.rate_limit_new_user_create_post = 30
    end

    it "для новичка берёт окно новичка" do
      expect(newbie.new_user?).to eq(true)
      post = post_in(bot_pm(newbie), newbie)
      expect(limiter).to receive(:rollback!).once
      described_class.new(post).apply!
      expect(cap_ttl(post)).to be_within(3).of(30)
    end

    it "для не-новичка берёт общее окно" do
      expect(author.new_user?).to eq(false)
      post = post_in(bot_pm)
      expect(limiter).to receive(:rollback!).once
      described_class.new(post).apply!
      expect(cap_ttl(post)).to be_within(3).of(5)
    end

    it "молчит, когда ограничитель отключён нулевым окном" do
      SiteSetting.rate_limit_create_post = 0
      expect(limiter).not_to receive(:rollback!)
      described_class.new(post_in(bot_pm)).apply!
    end
  end

  # Послабление — не критичный путь. Если оно сломалось, пост всё равно должен
  # создаться, а портал — вернуться к штатному поведению ядра.
  describe "деградация" do
    it "не роняет пост, когда redis недоступен" do
      # Фикстуру собираем ДО подмены: Discourse.cache ходит в тот же redis,
      # и заглушка на setex иначе срабатывает ещё на валидации поста.
      post = post_in(bot_pm)
      allow(Discourse.redis).to receive(:setex).and_raise(
        Redis::CannotConnectError.new("нет связи с redis"),
      )
      expect(Discourse).to receive(:warn_exception).once
      expect(limiter).not_to receive(:rollback!)
      expect { described_class.new(post).apply! }.not_to raise_error
    end

    it "не роняет пост, когда discourse-ai отвечает ошибкой" do
      allow(::DiscourseAi::AiBot::EntryPoint).to receive(:all_bot_ids).and_raise(
        StandardError.new("ai сломан"),
      )
      expect(Discourse).to receive(:warn_exception).once
      expect(limiter).not_to receive(:rollback!)
      expect { described_class.new(post_in(bot_pm)).apply! }.not_to raise_error
    end
  end
end
