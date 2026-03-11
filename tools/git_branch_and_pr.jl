module git_branch_and_pr
const prosca = parentmodule(@__MODULE__)

const name = "git_branch_and_pr"
const schema = """{"tool": "git_branch_and_pr", "args": {"repo_path": "...", "task": "...", "changes_summary": "..."}}"""
const needs_confirm = true

function fn(args)::String
  token = prosca.CONFIG["github_token"]
  isempty(token) && return "Set github_token in config.yaml"
  repo_path, task, changes_summary = args.repo_path, args.task, args.changes_summary
  repo = prosca.LibGit2.GitRepo(repo_path)
  branch_name = "prosca/$(replace(lowercase(task), r"[^a-z0-9]+" => "-")[1:min(50, end)])"

  prosca.LibGit2.checkout_branch(repo, branch_name; force=true)
  prosca.LibGit2.add!(repo, ".")
  prosca.LibGit2.commit(repo, "prosca: $task\n\n$changes_summary")
  prosca.LibGit2.push(repo, "origin", branch_name)

  remote_url = prosca.LibGit2.getconfig(repo, "remote.origin.url")
  repo_name = match(r"github\.com[:/](.+?)\.git", remote_url)[1]
  api_url = "https://api.github.com/repos/$repo_name/pulls"
  body = prosca.JSON3.write(Dict(
    "title" => "prosca: $task",
    "body" => "Automated by Prosca.\n\n**Summary:** $changes_summary\n\n**Branch:** $branch_name",
    "head" => branch_name,
    "base" => prosca.LibGit2.headname(repo)
  ))
  resp = prosca.HTTP.post(api_url, ["Authorization" => "token $token"], body)
  pr_url = prosca.JSON3.read(resp.body)["html_url"]
  "✅ PR created: $pr_url"
end

end
