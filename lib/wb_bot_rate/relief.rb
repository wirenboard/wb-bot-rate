# frozen_string_literal: true

module WbBotRate
  # Откат ограничителя частоты постинга для автора поста, если пост создан в
  # личной теме, среди участников которой есть учётка ИИ-бота.
  #
  # Приём повторяет ядро: plugins/discourse-narrative-bot/lib/discourse_narrative_bot/actions.rb,
  # метод reset_rate_limits. К моменту события :post_created ограничитель уже
  # сработал в after_create (lib/rate_limiter/on_create_record.rb) и положил
  # отметку времени в список Redis. rollback! снимает её обратно (LPOP), поэтому
  # следующее сообщение в окно не упирается.
  #
  # Потолок обязателен: без него бот-диалог можно завести за секунду и
  # ограничение частоты на портале перестанет существовать. Счётчик откатов
  # живёт в Redis ровно длину окна ограничителя и считается по паре
  # тема + пользователь.
  class Relief
    ROLLBACK_KEY_PREFIX = "wb-bot-rate:rollbacks"

    def initialize(post)
      @post = post
    end

    def apply!
      return unless SiteSetting.wb_bot_rate_enabled
      return unless eligible?

      duration = limiter_duration
      return if duration <= 0

      max = SiteSetting.wb_bot_rate_max_rollbacks.to_i
      return if max <= 0

      count = Discourse.redis.get(cap_key)
      if count.nil?
        count = 0
        Discourse.redis.setex(cap_key, duration, count)
      end
      return if count.to_i >= max

      @post.default_rate_limiter&.rollback!
      Discourse.redis.incr(cap_key)
    rescue StandardError => e
      # Послабление — не критичный путь: оно не должно ронять создание поста.
      Discourse.warn_exception(e, message: "wb-bot-rate: откат ограничителя не удался")
    end

    private

    def eligible?
      # PostCreator с skip_validations вообще не записывает отметку
      # (lib/post_creator.rb: @post.disable_rate_limits! if skip_validations?),
      # откатывать в этом случае нечего — LPOP снял бы чужую, более раннюю отметку.
      return false if @post.nil? || @post.skip_validation

      user = @post.user
      return false if user.nil?
      return false if user.staff?          # персонал ограничитель и так не видит
      return false if user.id.to_i <= 0    # ответы самого бота нас не касаются

      topic = @post.topic
      return false if topic.nil? || !topic.private_message?

      bot_ids = ai_bot_user_ids
      return false if bot_ids.empty?

      # Именно участие бота в теме, а не «тема личная»: обычная переписка
      # между людьми послабления получать не должна.
      topic.topic_allowed_users.where(user_id: bot_ids).exists?
    end

    # Учётки ИИ-ботов: агенты discourse-ai плюс пользователи включённых LlmModel.
    # Здесь нельзя брать Playground.is_bot_user_id? — это просто user_id <= 0,
    # под него попадают и system (-1), и discobot (-2).
    def ai_bot_user_ids
      return [] unless defined?(::DiscourseAi::AiBot::EntryPoint)
      return [] unless SiteSetting.respond_to?(:discourse_ai_enabled)
      return [] unless SiteSetting.discourse_ai_enabled

      ::DiscourseAi::AiBot::EntryPoint.all_bot_ids.compact.uniq
    rescue StandardError => e
      Discourse.warn_exception(e, message: "wb-bot-rate: не удалось получить список ботовых учёток")
      []
    end

    # Та же развилка, что в RateLimiter::OnCreateRecord#default_rate_limiter.
    def limiter_duration
      if @post.user&.new_user?
        SiteSetting.rate_limit_new_user_create_post.to_i
      else
        SiteSetting.rate_limit_create_post.to_i
      end
    end

    def cap_key
      "#{ROLLBACK_KEY_PREFIX}:#{@post.topic_id}:#{@post.user_id}"
    end
  end
end
