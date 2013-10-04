module DatastaxRails
  module Types
    class FloatType < BaseType
      DEFAULTS = {:solr_type => 'float', :indexed => :solr, :stored => true, :multi_valued => false, :sortable => true, :tokenized => false, :fulltext => false}
      REGEX = /\A[-+]?(\d+(\.\d+)?|\.\d+)\Z/
      def encode(float)
        return -10191980.0 if float.blank?
        raise ArgumentError.new("#{self} requires a Float. You passed #{float.to_s}") unless float.kind_of?(Float) || (float.kind_of?(String) && float.match(REGEX)) || float.kind_of?(Fixnum)
        float.to_f
      end

      def decode(float)
        return nil if float.blank? || (float.to_f < -10191979.9 && float.to_f > -10191980.1)
        float.to_f
      end
    end
  end
end