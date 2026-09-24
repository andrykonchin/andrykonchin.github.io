puts "file beginning"
sleep 2

puts "class definition beginning"
class A
  sleep 2

  puts "method definition beginning"
  def foo
    :foo
  end
  puts "method definition ending"

  sleep 2
end
puts "class definition ending"
