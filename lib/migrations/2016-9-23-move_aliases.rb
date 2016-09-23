require 'mongo'
require 'optparse'

module PagerBot
  class MoveAliasesMigration
      def db
        return @db unless @db.nil?
        if ENV['MONGODB_URI']
          client = Mongo::MongoClient.from_uri(ENV['MONGODB_URI'])
          db_name = ENV['MONGODB_URI'][%r{/([^/\?]+)(\?|$)}, 1]
        else
          client = Mongo::MongoClient.new
          db_name = "pagerbot"
        end

        @db = client.db(db_name)
      end
        
      # grab all users and schedules
      # for each one, grab its aliases,
      # and spit that into another collection, keyed on alias
      # {_id: alias, pagerduty_id: PDID, type: user/schedule}
      def update_collection(collection, type, real)
        result = db[collection].find({})
        result.each do |pd_obj|
          aliases = pd_obj['aliases'] || []
          aliases.each do |ali|
            if real
              db[collection].insert({_id: ali, pagerduty_id: pd_obj['id'], type: type})
            else
              puts("Would have inserted #{ali} into the database for #{type} #{pd_obj['name']}")
            end
          end
        end
      end

      def run!(real=false)
        update_collection('users', 'user', real)
        update_collection('schedules', 'schedule', real)
      end
  end
end

if __FILE__ == $0
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: 2016-9-23-move-aliases.rb [options]"

    opts.on("-r", "--real", "Run the migration with side effects") do
      options[:real] = true
    end
  end.parse!
  PagerBot::MoveAliasesMigration.new.run!(options[:real])
end