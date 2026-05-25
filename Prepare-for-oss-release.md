# Prepare for oss release

## documentation

### Find a good static site rendered solution

- Page needs to be scalable when nix options are huge
- will be hosted on github pages
- Should be able to auto generate from a directory of markdown and the navigation in the directory structure should map to the navigation in the rendered static site.

### Clean up

- Remove comments.
  - Comments for helping guide the llm should be removed.
  - Prefer no comments, but exceptions can be made for things that need clarity
  - If something needs to be explained it is better to have good documentation and have examples when necessary

- Remove dead code
- Clean up confusing code

### Write documentation

1. Part of the rendered static site should have the module options exposed by catallaxy.

2. The rest of the documentation is taking markdown and rendering it into a "book" if that is the static site generator. Basically don't rely on github docs or anything.
   - Main README.md should
     - Give description of project
     - Explain the concept of catallaxy and the desire to have a way to build devops using that principle
     - Point to the static site for full documentation

### Static site docs

#### Getting started

#### Archetecture

#### Todo/milestones

#### Contributors guide

#### A recipe or situation based documentation section.

Basically some ways to use it, or documenting flows that require more steps.

##### Example: homelab example setting up oidc (demonstrating that scripts understand topology of lab)

1. lab up
2. trust
3. setup dns
4. init-user lab-dev
5. login to kanidm
