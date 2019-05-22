module Jabber

  module Register

    NS_REGISTER =  'jabber:iq:register'
      
    class Responder
      attr_accessor :instructions
      
      def initialize(stream)
        @stream = stream
        @fields = []
        @registered_callbacks = []
        
        @stream.add_iq_callback() do |iq|
          if iq.query.kind_of?(IqQueryRegister) then
            if iq.type == :get then  # Registration request 
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryRegister.new)
              query.add(Field.new(:instructions, @instructions)) unless instructions.nil?
              @fields.each do |field| query.add(Field.new(field[0])) end 
              @stream.send(answer)
            elsif iq.type == :set then # Registration response
              iq.query.each do |field|
                validator = @fields.assoc(field.name.to_sym)[2]
                if !validator.call(iq.from, field.text) then
                  puts "- - n0t acceptable here - -"
                  answer = iq.answer(true)
                  answer.type = :error
                  answer.add(Jabber::ErrorResponse.new('not-acceptable'))
                  @stream.send(answer)
                end
              end
              
              # let them know that all looks good!
              answer = iq.answer(false)
              answer.type = :result
              @stream.send(answer)
              
              # Fire off callbacks
              @registered_callbacks.each do |cb|
                cb.call(iq.from)
              end
            end
          end
        end
      end
      
      def add_field(name, required, &validator) 
        @fields << [ name, required, validator ] 
      end
      
      def add_registered_callback(&cb)
        @registered_callbacks << cb
      end
    end
  end

  class IqQueryRegister < IqQuery
    name_xmlns 'query', Jabber::Register::NS_REGISTER
  end
  
  class Field < REXML::Element
    def initialize(name, value=nil)
      super(name.to_s)
      self.text = value
    end
  end
end
