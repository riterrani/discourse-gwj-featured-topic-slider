/* global settings */

import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import FeaturedTopicSlider from "./featured-topic-slider";
import { isRouteEnabled } from "../lib/gwj-slider-placement";

export default class FeaturedTopicSliderMount extends Component {
  @service router;

  themeSettings = settings;

  @tracked currentRouteName = this.router.currentRouteName;
  @tracked currentPathname = window.location?.pathname || "/";

  constructor() {
    super(...arguments);
    this._routeHandler = this.handleRouteDidChange;
    this.router.on("routeDidChange", this._routeHandler);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    if (this._routeHandler) {
      this.router.off("routeDidChange", this._routeHandler);
      this._routeHandler = null;
    }
  }

  @action
  handleRouteDidChange(transition) {
    this.currentRouteName = transition?.to?.name || this.router.currentRouteName;
    this.currentPathname = window.location?.pathname || "/";
  }

  get placement() {
    return this.args.placement || "top";
  }

  get insertMode() {
    return this.themeSettings.insert_mode || "after_n";
  }

  get matchesPlacement() {
    switch (this.placement) {
      case "before_main":
        return this.insertMode === "before_main";
      case "before_navigation":
        return this.insertMode === "before_navigation";
      case "top":
        return this.insertMode === "before_list" || this.insertMode === "after_n";
      case "bottom":
        return this.insertMode === "list_footer";
      default:
        return false;
    }
  }

  get routeAllowed() {
    return isRouteEnabled({
      showOn: this.themeSettings.show_on,
      routeName: this.currentRouteName,
      pathname: this.currentPathname,
    });
  }

  get shouldRender() {
    return this.matchesPlacement && this.routeAllowed;
  }

  get requiresDynamicPlacement() {
    return this.placement === "top" && this.insertMode === "after_n";
  }

  get cacheContext() {
    return `${this.currentPathname || "/"}::${this.placement}`;
  }

  <template>
    {{#if this.shouldRender}}
      {{#if this.requiresDynamicPlacement}}
        <div
          class="gwj-featured-topic-slider-anchor"
          data-featured-topic-slider-anchor="dynamic"
        >
          <FeaturedTopicSlider @cacheContext={{this.cacheContext}} />
        </div>
      {{else}}
        <FeaturedTopicSlider @cacheContext={{this.cacheContext}} />
      {{/if}}
    {{/if}}
  </template>
}
