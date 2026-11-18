require 'js'
require 'shout'
require_relative 'greeter/version'

module Greeter
  # Waits for a JavaScript Promise while the library itself is being
  # evaluated. A library run with `load` would stop silently here, and
  # Greeter.greet below would never be defined.
  GREETING = JS.eval('new Promise(resolve => setTimeout(() => resolve("Hello"), 10))').await

  def self.greet(name)
    Shout.shout("#{GREETING}, #{name}") + " (greeter #{VERSION})"
  end

  # Waits for a JavaScript Promise. This works only because the library is
  # inlined into the task of the script that requires it.
  def self.later(value)
    JS.global[:__greeter_value] = value
    JS.eval('new Promise(resolve => setTimeout(() => resolve(window.__greeter_value), 10))').await
  end
end
