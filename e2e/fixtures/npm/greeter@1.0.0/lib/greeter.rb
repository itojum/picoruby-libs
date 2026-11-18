require 'js'
require 'shout'
require_relative 'greeter/version'

module Greeter
  def self.greet(name)
    Shout.shout("Hello, #{name}") + " (greeter #{VERSION})"
  end

  # Waits for a JavaScript Promise. This works only because the library is
  # inlined into the task of the script that requires it.
  def self.later(value)
    JS.global[:__greeter_value] = value
    JS.eval('new Promise(resolve => setTimeout(() => resolve(window.__greeter_value), 10))').await
  end
end
