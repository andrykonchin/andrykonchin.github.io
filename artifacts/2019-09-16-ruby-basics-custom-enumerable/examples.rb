require 'csv'
require 'benchmark'

def print_memory_usage
  GC.start

  memory_before = `ps -o rss= -p #{Process.pid}`.to_i
  yield
  memory_after = `ps -o rss= -p #{Process.pid}`.to_i

  puts "Memory: #{((memory_after - memory_before) / 1024.0).round(2)} MB"
end

def print_time_spent
  time = Benchmark.realtime do
    yield
  end

  puts "Time: #{time.round(2)}"
end



# ==========

FILE = 'create-enumerable.csv'

puts "======= CSV.read"

print_time_spent do
print_memory_usage do

csv = CSV.read(FILE, headers: true)
csv.each do |row|
  p row
end


puts "======== CSV.new/shift"

File.open(FILE, 'r') do |file|
  csv = CSV.new(file, headers: true)

  while row = csv.shift
    p row
  end
end

puts "======== CSV.foreach"

CSV.foreach(FILE, headers: true) do |row|
  p row
end

puts "======== Enumerable"

class LazyCSVCollection
  include Enumerable

  def initialize(path, options = nil)
    @path = path
    @options = options || {}
  end

  def each
    File.open(@path, 'r') do |file|
      csv = CSV.new(file, @options)

      while row = csv.shift
        yield row
      end
    end
  end
end


seq = LazyCSVCollection.new(FILE, headers: true)
seq.each { |h| p h }

puts "======== Enumerator"

path = FILE
options = { headers: true }

seq = Enumerator.new do |y|
  File.open(path, 'r') do |file|
    csv = CSV.new(file, options)

    while row = csv.shift
      y << row
    end
  end
end

seq.each { |h| p h }


puts "======== raw interface"

path = FILE
options = { headers: true }

File.open(path, 'r') do |file|
  csv = CSV.new(file, options)
  csv.each.each { |h| p h }
end


puts "======== to_enum (foreach)"

path = FILE
options = { headers: true }

File.open(path, 'r') do |file|
  seq = CSV.to_enum(:foreach, file, options)
  seq.each { |h| p h }
end

# ➜  aazonsoftware git:(master) ✗ ruby ./create-enumerable.rb
# ======= CSV.read
# Memory: 566.21 MB
# Time: 3.34
# ======== CSV.new/shift
# Memory: 114.52 MB
# Time: 3.53
# ======== CSV.foreach
# Memory: 110.18 MB
# Time: 4.13
# ======== Enumerable
# Memory: 75.4 MB
# Time: 4.2
# ======== Enumerator
# Memory: 57.79 MB
# Time: 4.58
# ======== raw interface
# ======== to_enum (foreach)
# Memory: 92.68 MB
# Time: 3.91
# ➜  aazonsoftware git:(master) ✗ ruby ./create-enumerable.rb
# ======= CSV.read
# Memory: 566.84 MB
# Time: 3.34
# ======== CSV.new/shift
# Memory: 114.71 MB
# Time: 3.52
# ======== CSV.foreach
# Memory: 111.09 MB
# Time: 3.83
# ======== Enumerable
# Memory: 71.65 MB
# Time: 3.88
# ======== Enumerator
# Memory: 61.61 MB
# Time: 3.94
# ======== raw interface
# Memory: 53.78 MB
# Time: 4.67
# ======== to_enum (foreach)
# Memory: 49.76 MB
# Time: 3.61
# ➜  aazonsoftware git:(master) ✗ ruby ./create-enumerable.rb
# ======= CSV.read
# Memory: 566.47 MB
# Time: 3.19
# ======== CSV.new/shift
# Memory: 109.46 MB
# Time: 4.09
# ======== CSV.foreach
# Memory: 108.9 MB
# Time: 4.06
# ======== Enumerable
# Memory: 74.22 MB
# Time: 3.98
# ======== Enumerator
# Memory: 59.26 MB
# Time: 4.41
# ======== raw interface
# Memory: 51.63 MB
# Time: 3.3
# ======== to_enum (foreach)
# Memory: 48.86 MB
# Time: 5.5
