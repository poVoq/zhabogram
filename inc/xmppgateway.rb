module Jabber
  module Gateway

    NS_GATEWAY =  'jabber:iq:gateway'
    
    class Responder
      attr_accessor :description
      attr_accessor :prompt
      
      def initialize(stream, &func)
        @stream = stream
        @func = func
          
        @stream.add_iq_callback() do |iq|
          if iq.query.kind_of?(IqQueryGateway)
            if iq.type == :get
              # Client is requesting fields
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryGateway.new)
              query.desc = @description || ''
              query.prompt = @prompt || ''
              @stream.send(answer)
            elsif iq.type == :set
              # Client is requesting full JID
              query = iq.query.prompt
              jid = @func.call(iq, query)
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryGateway.new)
              query.jid = jid
              @stream.send(answer)
            end
          end
        end
      end
    end
   
    class IqQueryGateway < IqQuery
      name_xmlns 'query', Jabber::Gateway::NS_GATEWAY
      
      def desc
        first_element_text('desc')
      end
      
      def desc=(new_desc)
        replace_element_text('desc', new_desc)
      end
      
      def prompt
        first_element_text('prompt')
      end
      
      def prompt=(new_prompt)
        replace_element_text('prompt', new_prompt)
      end
      
      def jid
        first_element_text('jid')
      end
      
      def jid=(new_prompt)
        replace_element_text('jid', new_prompt)
      end
    end
    
  end
end
