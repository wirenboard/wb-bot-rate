# frozen_string_literal: true

# name: wb-bot-rate
# about: Откатывает форумное ограничение частоты постинга внутри личных диалогов с ИИ-ботом
# version: 0.1.0
# authors: Wiren Board
# url: https://github.com/wirenboard/wb-bot-rate
# required_version: 2.7.0

enabled_site_setting :wb_bot_rate_enabled

module ::WbBotRate
  PLUGIN_NAME = "wb-bot-rate"
end

after_initialize do
  require_relative "lib/wb_bot_rate/relief"

  # :post_created срабатывает уже после after_create у Post, то есть после того,
  # как ограничитель записал отметку. Поэтому здесь именно откат, а не отключение.
  on(:post_created) { |post, _opts, _user| ::WbBotRate::Relief.new(post).apply! }
end
