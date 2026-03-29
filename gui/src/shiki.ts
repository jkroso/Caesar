import { createHighlighterCoreSync } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import julia from "@shikijs/langs/julia";
import javascript from "@shikijs/langs/javascript";
import json from "@shikijs/langs/json";
import python from "@shikijs/langs/python";
import bash from "@shikijs/langs/bash";
import theme from "@shikijs/themes/github-dark-dimmed";

export const highlighter = createHighlighterCoreSync({
  themes: [theme],
  langs: [julia, javascript, json, python, bash],
  engine: createJavaScriptRegexEngine(),
});

export const defaultTheme = "github-dark-dimmed";
