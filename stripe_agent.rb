require 'yaml'
require 'stripe'
require 'base64'
require 'iron_cache'
# Requires manual installation of the New Relic plaform gem
# https://github.com/newrelic-platform/iron_sdk
require 'newrelic_platform'

# Un-comment to test/debug locally
# def config; @config ||= YAML.load_file('./stripe_agent.config.yml'); end

# Setup

# Configure Stripe client
Stripe.api_key = config['stripe']['api_key']

STRIPE_MAX_COUNT = 100

# Configure NewRelic client
@new_relic = NewRelic::Client.new(:license => config['newrelic']['license'],
                                  :guid => config['newrelic']['guid'],
                                  :version => config['newrelic']['version'])

# Configure IronCache client
begin
  @cache = IronCache::Client.new(config['iron']).cache("newrelic-stripe-agent")
rescue Exception => err
  abort 'Iron.io credentials are wrong.'
end

# Helpers
def stderr_to_stdout
  $stderr_backup = $stderr unless $stderr_backup
  $stderr = $stdout
end

def restore_stderr
  $stderr = $stderr_backup if $stderr_backup
end

def duration(from, to)
  dur = from ? (to - from).to_i : 3600

  dur > 3600 ? 3600 : dur
end

def up_to(to = nil)
  if to
    @up_to = Time.at(to.to_i).utc
  else
    @up_to ||= Time.now.utc
  end
end

def processed_at(processed = nil)
  if processed
    @cache.put('previously_processed_at', processed.to_i)

    @processed_at = Time.at(processed.to_i).utc
  elsif @processed_at.nil?
    item = @cache.get 'previously_processed_at'
    min_prev_allowed = (up_to - 3600).to_i

    at = if item && item.value.to_i > min_prev_allowed
           item.value
         else
           min_prev_allowed
         end

    @processed_at = Time.at(at).utc
  else
    @processed_at
  end
end

def generate_random_data(count = 3)
  (1..count).each_with_object([]) do |_, data|
    # amount is in range $200..999
    amount = Random.rand(800) + 200
    # fee rate is in 3..10%
    fee_rate = (Random.rand(8) + 3) / 100.0

    data << {:currency => 'usd', :amount => amount, :fee => fee_rate * amount}
  end
end

def rounded(data)
  data.each_with_object({}) { |(k, v), res| res[k] = v.round(2) }
end

def process_to(component, stat_class, opts = {})
  default_stat = {
    :min => 0.0,
    :max => 0.0,
    :total => 0.0,
    :count => 0.0,
    :sum_of_squares => 0.0
  }
  offset = 0
  objects = []
  stats = {}

  begin
    objects = unless config['test_mode']
                begin
                  stat_class.all({ :count => STRIPE_MAX_COUNT,
                                   :offset => offset }.merge(opts))
                rescue Exception => err
                  restore_stderr
                  if err.message =~ /Invalid API Key provided/
                    abort 'Invalid Stripe API Key.'
                  else
                    abort("Error happened while retrieving data from Stripe. " +
                          "Error message: '#{err.message}'.")
                  end
                end
              else
                generate_random_data
              end

    objects.each do |object|
      currency = object[:currency].to_sym
      stats[currency] ||= {
        :amount => default_stat.dup,
        :fee => default_stat.dup
      }

      by_currency = stats[currency]

      amount = by_currency[:amount]
      amnt_val = object[:amount]
      if amount[:min] == 0 || amnt_val < amount[:min]
        amount[:min] = amnt_val
      end
      amount[:max] = amnt_val if amnt_val > amount[:max]
      amount[:total] += amnt_val
      amount[:count] += 1
      amount[:sum_of_squares] += amnt_val ** 2

      fee = by_currency[:fee]
      fee_val = object[:fee]
      if fee[:min] == 0 || fee_val < fee[:min]
        fee[:min] = fee_val
      end
      fee[:max] = fee_val if fee_val > fee[:max]
      fee[:total] += fee_val
      fee[:count] += 1
      fee[:sum_of_squares] += fee_val ** 2
    end

    offset += STRIPE_MAX_COUNT
  end while objects.count == STRIPE_MAX_COUNT

  # Send stats to New Relic
  stats.each do |currency, stat|
    stat.each do |name, values|
      puts "#{stat_class.class_name}s/#{name.capitalize} (#{currency}): #{values.inspect}"
      component.add_metric("#{stat_class.class_name}s/#{name.capitalize}",
                           currency.to_s,
                           rounded(values))
    end
  end
end

def process_and_post_stats
  collector = @new_relic.new_collector
  component = collector.component 'Stripe'
  # Request stats up to current time
  up_to

  yield component

  component.options[:duration] = duration(processed_at, up_to)
  begin
    # submit statistics
    collector.submit
  rescue Exception => err
    restore_stderr
    if err.message.downcase =~ /http 403/
      abort "Seems New Relic's license key is wrong."
    else
      abort("Error happened while sending data to New Relic. " +
            "Error message: '#{err.message}'.")
    end
  end

  processed_at up_to
end


# Processing
stderr_to_stdout
process_and_post_stats do |component|
  # Stripe's Charges
  process_to(component,
             Stripe::Charge,
             {:created => {
                 :gt => processed_at.to_i,
                 :lte => up_to.to_i
               }
             })

  # Stripe's Transfers
  process_to(component,
             Stripe::Transfer,
             {:date => {
                 :gt => processed_at.to_i,
                 :lte => up_to.to_i
               }
             })
end
