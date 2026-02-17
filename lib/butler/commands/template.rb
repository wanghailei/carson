# frozen_string_literal: true

module Butler
	module Commands
		class TemplateCheck
			def self.run( runtime: )
				runtime.template_check!
			end
		end

		class TemplateApply
			def self.run( runtime: )
				runtime.template_apply!
			end
		end
	end
end
