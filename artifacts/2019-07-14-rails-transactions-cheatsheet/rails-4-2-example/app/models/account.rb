class Account < ActiveRecord::Base
  has_many :payments
end
