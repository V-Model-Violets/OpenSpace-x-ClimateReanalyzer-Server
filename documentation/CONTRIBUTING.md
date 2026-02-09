# Contributing to `OpenSpace-x-ClimateReanalyzer-UI`
Contributors to `OpenSpace-x-ClimateReanalyzer-UI` are expected to follow these guidelines:

## Pull Requests
All changes to the repo require a Pull Request and approval upon merging into the base branch. The intent of a Pull Request is to allow for changes to be reviewed before being merged into the base branch

## Commits
Commits should be crafted to follow a specific format to allow for readability and organization

### Commit Message Format
```
<type>: <description>

#<GitHub-Issue-Number>
```

#### Type
The type in the header must be one of the following:

|Name|Description|
|-|-|
|feat|Changes that introduce functionality.|
|fix|Changes that fix a bug.|
|test|Changes that add new tests or update tests.|
|refactor|Stylistic changes to the code (won't change functionality)|
|ci|Update Github Action workflows.|
|docs|Updates or additions to any documentation.|
|chore|Changes to repository content that do not affect compilation, such as `CODEOWNERS` changes.|

### Atomic Commits
Commits must be atomic. Here is more: [Atomic Commits](https://en.wikipedia.org/wiki/Atomic_commit). TLDR: "This commit does one thing and one thing only".

## Branches
Branche names should follow a similar format to the commit messages. 

### Branch Naming Convention
```
<type>/<description>
```

### Example
If there were a branch, and the goal for that branch is to create a new page, the naming would go something like this:
```
feat/add-<page-name>-page
```
