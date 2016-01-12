require 'twitter_ebooks'
require './wordfilter.rb'
require './config.rb'

include Ebooks

$banned_words = BANNED_WORDS

# Information about a particular Twitter user we know
class UserInfo
  attr_reader :username

  # @return [Integer] how many times we can pester this user unprompted
  attr_accessor :pesters_left

  # @param username [String]
  def initialize(username)
    @username = username
    @pesters_left = 1
  end
end

class Ebooks::Model
  def valid_tweet?(tikis, limit)
    tweet = NLP.reconstruct(tikis, @tokens)

    found_banned = $banned_words.any? do |word|
      re = Regexp.new("\\b#{word}\\b", "i")
      re.match tweet
    end

    found_wordfilter = Wordfilter::blacklisted?(tweet)

    puts("tweet: #{tweet}")
    puts("found_banned: #{found_banned}")
    puts("found_wordfilter: #{found_wordfilter}")

    tweet.length <= limit && !NLP.unmatched_enclosers?(tweet) && !found_banned && !found_wordfilter
  end

  def make_statement(limit=140, generator=nil, retry_limit=10)
    responding = !generator.nil?
    generator ||= SuffixGenerator.build(@sentences)

    retries = 0
    tweet = ""

    while (tikis = generator.generate(3, :bigrams)) do
      log "Attempting to produce tweet try #{retries+1}/#{retry_limit}"
      next if tikis.length <= 3 && !responding
      break if valid_tweet?(tikis, limit)

      retries += 1
      break if retries >= retry_limit
    end

    if verbatim?(tikis) && tikis.length > 3 # We made a verbatim tweet by accident
      log "Attempting to produce unigram tweet try #{retries+1}/#{retry_limit}"
      while (tikis = generator.generate(3, :unigrams)) do
        break if valid_tweet?(tikis, limit) && !verbatim?(tikis)

        retries += 1
        break if retries >= retry_limit
      end
    end

    tweet = NLP.reconstruct(tikis, @tokens)

    if retries >= retry_limit
      log "Unable to produce valid non-verbatim tweet"

      tweet = "."
    end

    fix tweet
  end
end

class CloneBot < Ebooks::Bot
  attr_accessor :original, :model, :model_path

  def configure
    self.blacklist = BANNED_USERS

    self.consumer_key = "tO9dGTyawGOevjwiu6CCPSp40"
    self.consumer_secret = "lO3q56taDVYoI3jNnl5Q34wSuXFBeekQ099aWFtSUm9r8MC1Hz"

    self.delay_range = 1..6

    @userinfo = {}
  end

  def top100; @top100 ||= model.keywords.take(100); end
  def top20;  @top20  ||= model.keywords.take(20); end

  def on_startup
    load_model!

    # tweet(model.make_statement)

    scheduler.cron '0 */3 * * *' do
      # every 3 hours, tweet
      tweet(model.make_statement)
    end
  end

  def on_message(dm)
    delay do
      reply(dm, model.make_response(dm.text))
    end
  end

  def on_mention(tweet)
    # Become more inclined to pester a user when they talk to us
    userinfo(tweet.user.screen_name).pesters_left += 1

    delay do
      reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
    end
  end

  def on_timeline(tweet)
    return if tweet.retweeted_status?
    return unless can_pester?(tweet.user.screen_name)

    tokens = Ebooks::NLP.tokenize(tweet.text)

    special = tokens.find { |t| SPECIAL_WORDS.include?(t) }
    interesting = tokens.find { |t| top100.include?(t.downcase) }
    very_interesting = tokens.find_all { |t| top20.include?(t.downcase) }.length > 2

    delay do
      if very_interesting
        favorite(tweet) if rand < 0.5
        retweet(tweet) if rand < 0.1
        if rand < 0.01
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      elsif interesting || special
        favorite(tweet) if rand < 0.05
        if rand < 0.001
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      end
    end
  end

  # Find information we've collected about a user
  # @param username [String]
  # @return [Ebooks::UserInfo]
  def userinfo(username)
    @userinfo[username] ||= UserInfo.new(username)
  end

  # Check if we're allowed to send unprompted tweets to a user
  # @param username [String]
  # @return [Boolean]
  def can_pester?(username)
    userinfo(username).pesters_left > 0
  end

  # don't follow anyone
  def can_follow?(username)
    false
  end

  def favorite(tweet)
    # if can_follow?(tweet.user.screen_name)
    #   super(tweet)
    # else
    #   log "Unfollowing @#{tweet.user.screen_name}"
    #   twitter.unfollow(tweet.user.screen_name)
    # end
  end

  def on_follow(user)
    # do nothing
  end

  private
  def load_model!
    return if @model

    @model_path ||= "model/#{original}.model"

    log "Loading model #{model_path}"
    @model = Ebooks::Model.load(model_path)
  end
end

CloneBot.new("sui_ebooks") do |bot|
  bot.access_token = "2557744674-fiXejJfGyHIvcqqZqEoIpfeGrI90ske6kNfc8Y6"
  bot.access_token_secret = "JRLaQYPAFe06W8eKOQ8D52DmZqXNVZEPtlTKEyBYsCOIl"

  bot.original = "swayandsea"
end
