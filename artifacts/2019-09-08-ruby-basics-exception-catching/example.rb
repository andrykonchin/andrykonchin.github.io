begin
  raise
rescue
  puts 'from rescue'
end

# from rescue

begin
  1/0
rescue
  0
end

# => 0

begin
  1
rescue
  0
else
  Float::INFINITY
end

# => Infinity

begin
else
end
# SyntaxError ((irb):3: else without rescue is useless)

begin
  @file = File.open('foo.txt', 'w')
  raise
ensure
  @file.close
end

begin
  # ...
rescue
  # do something that may change the result of the begin block
  retry
end

begin
  # ...
rescue
  # ...
else
  # this runs only when no exception was raised
ensure
  # ...
end

['1', 'a'].map do |s|
  Integer(s)
rescue
  Float::INFINITY
end

# => [1, Infinity]

['1', 'a'].map { |s|
  Integer(s)
rescue
}

# SyntaxError ((irb):88: syntax error, unexpected rescue, expecting '}')
# rescue
# ^~~~~~

begin
  raise
rescue ArgumentError, NoMethodError, RuntimeError
end

begin
  raise
rescue *[StandardError]
  puts $!.class
end

exception_list = [StandardError]
begin
  raise
rescue *exception_list
  puts $!.class
end

begin
  exception_list = [StandardError]
  raise
rescue ArgumentError, *exception_list
  puts $!.class
end


begin
rescue *[(raise), StandardError]
  puts $!.class
end


rescuer = Class.new do
  def self.===(e)
    true
  end
end

begin
  raise
rescue rescuer
end

# => :from_rescue

begin
  raise "foo"
rescue Integer
end
# RuntimeError (foo)

begin
  raise
rescue Comparable
end

raise 1
# TypeError (exception class/object expected)


begin
  raise
rescue 'class'
end
# TypeError (class or module required for rescue clause)

def foo
  1/0
rescue
  Float::INFINITY
end
foo
# => Infinity

class A
  raise
rescue
  puts "from class A"
end

# from class A

class B
  raise
rescue
  puts "from class A"
end

class C
  raise
end

def foo
  return 'from foo'
ensure
  return 'from ensure'
end
foo

def foo
  raise
rescue
  return 'from rescue'
ensure
  return 'from ensure'
end
foo

def foo
  raise
rescue
  raise
ensure
  return 'from ensure'
end
foo

def foo
  raise
ensure
  return 'from ensure'
end
foo


begin
  puts "begin"
  raise
rescue
  puts "rescue"
else
  puts "else"
ensure
  puts "ensure"
end

obj = Object.new
def obj.exception()
  RuntimeError.new("Internal error")
end
raise obj

# RuntimeError (Internal error)
