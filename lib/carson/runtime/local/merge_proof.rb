# Shared local merge-proof detection for commands that need content-aware "already on main" evidence.
module Carson
	class Runtime
		module Local
			def merge_proof_for_branch( branch:, main_ref: config.main_branch )
				return merge_proof_not_applicable( main_ref: main_ref ) if branch.to_s == main_ref.to_s

				candidate = merge_proof_candidate( branch: branch, main_ref: main_ref )
				return candidate if candidate.fetch( :basis ) == "unavailable"

				trust = merge_proof_main_trust( main_ref: main_ref )
				return candidate if trust.fetch( :trusted )

				merge_proof_hash(
					applicable: true,
					proven: false,
					basis: "unavailable",
					summary: trust.fetch( :summary ),
					main_branch: main_ref,
					changed_files_count: candidate.fetch( :changed_files_count, 0 )
				)
			end

			def branch_absorbed_into_main?( branch: )
				merge_proof_for_branch( branch: branch ).fetch( :proven )
			end

		private

			def merge_proof_candidate( branch:, main_ref: )
				_, _, ancestor_success, ancestor_exit = git_run( "merge-base", "--is-ancestor", branch, main_ref )
				merge_base_text, merge_base_error, merge_base_success, = git_run( "merge-base", main_ref, branch )
				unless merge_base_success
					return merge_proof_unavailable(
						main_ref: main_ref,
						summary: merge_proof_command_failure_summary(
							remote_ref: merge_proof_remote_ref( main_ref: main_ref ),
							fallback: "proof unavailable — could not determine merge-base with #{main_ref}.",
							error_text: merge_base_error
						)
					)
				end

				merge_base = merge_base_text.to_s.strip
				return merge_proof_unavailable( main_ref: main_ref, summary: "proof unavailable — merge-base with #{main_ref} is empty." ) if merge_base.empty?

				changed_text, changed_error, changed_success, = git_run( "diff", "--name-only", merge_base, branch )
				unless changed_success
					return merge_proof_unavailable(
						main_ref: main_ref,
						summary: merge_proof_command_failure_summary(
							remote_ref: merge_proof_remote_ref( main_ref: main_ref ),
							fallback: "proof unavailable — could not list branch changes against #{main_ref}.",
							error_text: changed_error
						)
					)
				end

				changed_files = changed_text.to_s.lines.map( &:strip ).reject( &:empty? )
				changed_files_count = changed_files.length

				if ancestor_success
					return merge_proof_hash(
						applicable: true,
						proven: true,
						basis: "ancestor",
						summary: "proven on main — branch tip is already on #{main_ref}.",
						main_branch: main_ref,
						changed_files_count: changed_files_count
					)
				end

				if ancestor_exit != 1
					return merge_proof_unavailable(
						main_ref: main_ref,
						summary: "proof unavailable — could not verify whether #{branch} is already on #{main_ref}.",
						changed_files_count: changed_files_count
					)
				end

				if changed_files.empty?
					return merge_proof_hash(
						applicable: true,
						proven: true,
						basis: "no_changes",
						summary: "proven on main — branch has no unique changes.",
						main_branch: main_ref,
						changed_files_count: 0
					)
				end

				_, _, identical, identical_exit = git_run( "diff", "--quiet", branch, main_ref, "--", *changed_files )
				if identical
					return merge_proof_hash(
						applicable: true,
						proven: true,
						basis: "content_identical",
						summary: "proven on main — #{changed_files_count} changed file#{plural_suffix( count: changed_files_count )} already #{merge_proof_files_verb( count: changed_files_count, singular: 'matches', plural: 'match' )} #{main_ref}.",
						main_branch: main_ref,
						changed_files_count: changed_files_count
					)
				end

				if identical_exit == 1
					return merge_proof_hash(
						applicable: true,
						proven: false,
						basis: "content_differs",
						summary: "not proven on main — #{changed_files_count} changed file#{plural_suffix( count: changed_files_count )} still #{merge_proof_files_verb( count: changed_files_count, singular: 'differs', plural: 'differ' )} from #{main_ref}.",
						main_branch: main_ref,
						changed_files_count: changed_files_count
					)
				end

				merge_proof_unavailable(
					main_ref: main_ref,
					summary: "proof unavailable — could not compare branch content against #{main_ref}.",
					changed_files_count: changed_files_count
				)
			end

			def merge_proof_main_trust( main_ref: )
				remote_ref = merge_proof_remote_ref( main_ref: main_ref )
				_, _, remote_exists, = git_run( "rev-parse", "--verify", remote_ref )
				unless remote_exists
					return {
						trusted: false,
						summary: "proof unavailable — no local #{remote_ref} reference."
					}
				end

				ahead_behind, _, sync_success, = git_run( "rev-list", "--left-right", "--count", "#{main_ref}...#{remote_ref}" )
				unless sync_success
					return {
						trusted: false,
						summary: "proof unavailable — could not compare local #{main_ref} with #{remote_ref}."
					}
				end

				ahead, behind = ahead_behind.to_s.strip.split.map( &:to_i )
				return { trusted: true, summary: "local #{main_ref} is in sync with #{remote_ref}." } if ahead.zero? && behind.zero?

				{
					trusted: false,
					summary: "proof unavailable — local #{main_ref} is not in sync with #{remote_ref}."
				}
			end

			def merge_proof_remote_ref( main_ref: )
				"#{config.git_remote}/#{main_ref}"
			end

			def merge_proof_not_applicable( main_ref: )
				merge_proof_hash(
					applicable: false,
					proven: false,
					basis: "not_applicable",
					summary: "not applicable — current branch is #{main_ref}.",
					main_branch: main_ref,
					changed_files_count: 0
				)
			end

			def merge_proof_unavailable( main_ref:, summary:, changed_files_count: 0 )
				merge_proof_hash(
					applicable: true,
					proven: false,
					basis: "unavailable",
					summary: summary,
					main_branch: main_ref,
					changed_files_count: changed_files_count
				)
			end

			def merge_proof_hash( applicable:, proven:, basis:, summary:, main_branch:, changed_files_count: )
				{
					applicable: applicable,
					proven: proven,
					basis: basis,
					summary: summary,
					main_branch: main_branch,
					changed_files_count: changed_files_count.to_i
				}
			end

			def merge_proof_files_verb( count:, singular:, plural: )
				count.to_i == 1 ? singular : plural
			end

			def merge_proof_command_failure_summary( remote_ref:, fallback:, error_text: )
				text = error_text.to_s.strip
				return fallback if text.empty?
				return "proof unavailable — local main is not in sync with #{remote_ref}." if text.include?( remote_ref ) && text.include?( "not a valid object name" )

				fallback
			end
		end
	end
end
