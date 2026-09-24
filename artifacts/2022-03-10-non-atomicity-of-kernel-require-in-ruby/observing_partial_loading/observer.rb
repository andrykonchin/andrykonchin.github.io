begin
  require './require'
rescue
  puts "exception was raised '#{$!}'"
end

class_defined = Object.const_defined?(:A)
foo_defined = class_defined && A.instance_methods.include?(:foo)
bar_defined = class_defined && A.instance_methods.include?(:bar)

puts "A defined? -> #{class_defined}"
puts "foo defined? -> #{foo_defined}"
puts "bar defined? -> #{bar_defined}"
