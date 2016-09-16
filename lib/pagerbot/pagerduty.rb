require 'active_support/time'
require 'chronic'
require 'chronic_duration'
require 'json'
require 'rest-client'
require_relative './models'

module PagerBot
  # Handle connecting to PagerDuty
  class PagerDuty
    attr_reader :users, :schedules

    def initialize(opts = {})
      pd_config = opts
      @subdomain = pd_config.fetch(:subdomain)
      @api_key = pd_config.fetch(:api_key)

      @users = PagerBot::Models::Collection.new(
        pd_config.fetch(:users, []), PagerBot::Models::User)
      @schedules = PagerBot::Models::Collection.new(
        pd_config.fetch(:schedules, []), PagerBot::Models::Schedule)

      headers_hash = { "Authorization" => "Token token=#{@api_key}" }
      @resource = RestClient::Resource.new(api_base,
        :headers => headers_hash)
    end
    def log
      PagerBot.log
    end

    def api_base
      "https://#{@subdomain}.pagerduty.com/api/v1"
    end

    def uri_base
      "https://#{@subdomain}.pagerduty.com"
    end

    def events_api_base
      "https://events.pagerduty.com/generic/2010-04-15/create_event.json"
    end

    def get(url, opts = {})
      begin
        resp = @resource[url].get(opts)
        answer = JSON.parse(resp, :symbolize_names => true)
        log.debug("GET #{url}, opts=#{opts.inspect}, response=#{answer.inspect}")
        answer
      rescue Exception => e
        params = opts[:params] ? "?#{opts[:params].inspect}" : ""
        log.error "Failed to get url: #{url}.\nOptions: #{opts.inspect}  #{@resource}"
        raise RuntimeError.new("Problem talking to PagerDuty: #{e.message}\n"+
          "Request was GET #{url}#{params}")
      end
    end

    def post(url, payload, opts = {})
      begin
        resp = @resource[url].post(payload, opts)
        answer = JSON.parse(resp, :symbolize_names => true)
        log.debug("POST #{url}, payload=#{payload.inspect}, "+
          "opts=#{opts.inspect}, response=#{answer.inspect}")
        answer
      rescue Exception => e
        params = opts[:params] ? "?#{opts[:params].inspect}" : ""
        log.error("Failed to post to url: #{url}.\nPayload: #{payload.inspect}"+
          "\nOptions: #{opts.inspect} #{@resource}")
        raise RuntimeError.new("Problem talking to PagerDuty: #{e.message}\n"+
          "Request was POST #{url}#{params} / #{payload.inspect}")
      end
    end

    def incidents_api
      base_url = "https://events.pagerduty.com/generic/2010-04-15/create_event.json"
      @incidents_resource ||= RestClient::Resource.new(base_url)
    end

    # post an incident to the incidents API
    def post_incident(payload)
      begin
        payload_json = JSON.dump(payload)
        resp = incidents_api.post(payload_json, :content_type => :json)
        answer = JSON.parse(resp, :symbolize_names => true)
        log.debug("POST to incidents, payload=#{payload.inspect}, response=#{answer}")
        answer
      rescue Exception => e
        log.error("Failed to post to incident API: #{payload.inspect}."+
          "\nError: #{e.message}")
        raise RuntimeError.new("Problem talking to PagerDuty incidents:"+
          " #{e.message}\nRequest was #{payload.inspect}")
      end
    end

    # return User object for aliases like "i", "johnsmith"
    def find_user(alias_, nickname=nil)
      if nickname && ['me', 'i', 'my'].include?(alias_)
        alias_ = nickname
      end
      user = @users.get(alias_)
      raise Pagerbot::UserNotFoundError.new("I don't know who #{alias_} is.") unless user
      return user
    end

    # schedule name => schedule object
    def find_schedule(schedule_name)
      schedule = @schedules.get(schedule_name)
      unless schedule
        raise Pagerbot::ScheduleNotFoundError.new("Can't find schedule named #{schedule_name}.")
      end
      return schedule
    end

    def next_oncall(person_id, schedule_id)
      response = get(
        "/schedules/#{schedule_id}",
        :params => {:include_next_oncall_for_user => person_id})
      response[:schedule][:next_oncall_for_user]
    end

    def parse_time(time, nick, extra_args={})
      begin
        person = find_user(nick)
        return person.parse_time(time, extra_args)
      rescue
        Chronic.time_class = Time
        return Chronic.parse(time, extra_args)
      end
    end

    private

    # reverses the collection of type {id => [aliases...]}
    # returning {alias => id}
    def index_collection(collection, alias_type)
      result = {}
      collection.each do |uid, aliases|
        aliases.each do |name|
          name = Utilities.normalize(name)
          (result[name] ||= Set.new) << uid
        end
      end

      result, rejected = result.partition { |_, uids| uids.length == 1 }

      rejected.each do |name, uids|
        log.warn("#{alias_type.capitalize} alias #{name} is ambiguous: " +
          "#{uids.inspect}. Excluding this alias")
      end

      Hash[result.map { |name, ids| [name, ids.first] }]
    end

    # add aliases for uid to collection and the reverse mapping of collection
    def add_to_collection(uid, aliases, collection, rev_map, type, add_alias=false)
      uid = uid.to_sym
      aliases = aliases.map { |a| Utilities.normalize(a) }
      unless add_alias || collection[uid].nil?
        raise ArgumentError.new(
          "#{type.capitalize} #{uid} (aliases: #{collection[uid]}) already exists!")
      end

      aliases.each do |name|
        raise ArgumentError.new(
          "#{type.capitalize} alias #{name} already exists!") unless rev_map[name].nil?
      end

      (collection[uid] ||= []) << aliases
      aliases.each do |name|
        rev_map[name] = uid
      end
    end
  end
end
