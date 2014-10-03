module ActiveHash
  class ScopedArray < SimpleDelegator
    def initialize(records, klass)
      super(records)
      @klass = klass
    end

    def all(options={})
      if options.has_key?(:conditions)
        where(options[:conditions])
      else
        self
      end
    end

    def where(options = nil)
      return self if options.nil?
      options.each {|name, value|
        type = @klass.field_types[name]
        if type && value != nil
          options[name] = value.send(ActiveHash.type_methods[type])
        end
      }
      self.class.new(select do |record|
        options.all? { |col, match| record[col] == match }
      end, @klass)
    end

    def not(options)
      self.class.new(select do |record|
        options.all? { |col, match| record[col] != match }
      end, @klass)
    end

    def count
      all.length
    end

    def find(id, * args)
      case id
        when nil
          nil
        when :all
          all
        when Array
          id.map { |i| find(i) }
        else
          @klass.find_by_id(id) || begin
            raise RecordNotFound.new("Couldn't find #{@klass.name} with ID=#{id}")
          end
      end
    end

    def find_by(options)
      where(options).first
    end
  end
end
