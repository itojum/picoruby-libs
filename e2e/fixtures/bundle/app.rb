require 'greeter'

puts "E2E greet: #{Greeter.greet('bundle')}"
puts "E2E await: #{Greeter.later('after a Promise')}"
puts 'E2E done'
