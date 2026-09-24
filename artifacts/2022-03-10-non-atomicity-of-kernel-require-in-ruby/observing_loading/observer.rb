Thread.new do
  loop do
    class_defined = Object.const_defined?(:A)
    method_defined = class_defined && A.instance_methods.include?(:foo)
    puts "A defined? -> #{class_defined} | foo defined? -> #{method_defined}"

    sleep 1
  end
end

Thread.new do
  require './require-2'
end.join
