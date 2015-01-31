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
      converted_options = {}
      options.each {|name, value|
        foptions = @klass.field_options[name]
        next unless foptions && (type = foptions[:type]) && value != nil
        convert = ActiveHash.converters[type]
        if value.is_a?(Array)
          converted_options[name] = value.map{|val|convert.try(val)}
        elsif !value.is_a?(Range)
          converted_options[name] = convert.try(value)
        end
      }
      self.class.new(select do |record|
        options.all? do |col, match|
          attr = record[col]
          if match.is_a?(Array)
            match.any? {|val| attr == val } || (converted_options[col] && converted_options[col].any? {|val| attr == val })
          elsif match.is_a?(Range)
            match.first <= attr && match.last >= attr
          else
            attr == match || (converted_options[col] && attr == converted_options[col])
          end
        end
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
