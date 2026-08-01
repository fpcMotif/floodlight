import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

const repository =
  process.env.PUBLIC_GITHUB_REPOSITORY ??
  process.env.GITHUB_REPOSITORY ??
  "vmg-dev/floodlight";
const [owner, repositoryName] = repository.split("/");
const isUserPagesRepository = repositoryName === `${owner}.github.io`;
const isGitHubPagesBuild = process.env.GITHUB_ACTIONS === "true";
const site = process.env.SITE_URL ?? `https://${owner}.github.io`;
const base =
  process.env.BASE_PATH ??
  (isGitHubPagesBuild && !isUserPagesRepository ? `/${repositoryName}` : "/");
const repositoryURL = `https://github.com/${repository}`;
const appIconPath = `${base.replace(/\/$/, "")}/app-icon.png`;
const appIconURL = new URL(appIconPath, site).href;

export default defineConfig({
  site,
  base,
  integrations: [
    starlight({
      title: "Floodlight",
      favicon: "/app-icon.png",
      logo: {
        src: "./src/assets/app-icon.png",
        alt: "",
      },
      description:
        "A fast, private Spotlight alternative for apps, files, folders, and settings.",
      customCss: ["./src/styles/custom.css"],
      lastUpdated: true,
      social: [
        {
          icon: "github",
          label: "Floodlight on GitHub",
          href: repositoryURL,
        },
      ],
      head: [
        {
          tag: "meta",
          attrs: {
            name: "theme-color",
            content: "#000000",
          },
        },
        {
          tag: "meta",
          attrs: {
            property: "og:image",
            content: appIconURL,
          },
        },
        {
          tag: "meta",
          attrs: {
            property: "og:image:alt",
            content: "Floodlight app icon.",
          },
        },
        {
          tag: "meta",
          attrs: {
            name: "twitter:image",
            content: appIconURL,
          },
        },
        {
          tag: "meta",
          attrs: {
            name: "twitter:image:alt",
            content: "Floodlight app icon.",
          },
        },
      ],
      sidebar: [
        {
          label: "Get started",
          items: [
            { label: "Quickstart", slug: "getting-started/quickstart" },
            {
              label: "Install & permissions",
              slug: "getting-started/install",
            },
            {
              label: "Replace Spotlight",
              slug: "getting-started/replace-spotlight",
            },
          ],
        },
        {
          label: "Using Floodlight",
          items: [
            { label: "Search", slug: "guides/search" },
            { label: "Filters", slug: "guides/filters" },
            {
              label: "Keyboard shortcuts",
              slug: "guides/keyboard-shortcuts",
            },
          ],
        },
        {
          label: "Reference",
          items: [
            {
              label: "Indexing",
              slug: "reference/indexing",
            },
            {
              label: "Troubleshooting",
              slug: "reference/troubleshooting",
            },
          ],
        },
        {
          label: "Development",
          items: [
            {
              label: "Build from source",
              slug: "development/building",
            },
          ],
        },
      ],
    }),
  ],
});
