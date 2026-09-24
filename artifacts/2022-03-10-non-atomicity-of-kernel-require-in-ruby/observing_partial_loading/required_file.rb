class A
  def foo
    :foo
  end

  raise 'Exception inside class definition'

  def bar
    :bar
  end
end
