require_relative 'lib/helper'
require 'local'

puts "E2E relative: #{Helper.double(21)}"
puts "E2E local: #{Local.where}"
puts 'E2E done'
