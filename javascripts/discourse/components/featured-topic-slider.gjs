/* global settings, themePrefix */

import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import getURL from "discourse/lib/get-url";
import { emojiUnescape } from "discourse/lib/text";
import { escapeExpression } from "discourse/lib/utilities";
import categoryBadge from "discourse/ui-kit/helpers/d-category-badge";
import icon from "discourse/ui-kit/helpers/d-icon";
import formatDate from "discourse/ui-kit/helpers/d-format-date";
import I18n, { i18n } from "discourse-i18n";
import { fetchFeaturedTopics } from "../lib/gwj-featured-topic-data";
import { resolveTopicImage } from "../lib/gwj-topic-images";

const TOPIC_CACHE = new Map();
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

export default class FeaturedTopicSliderComponent extends Component {
  @service site;

  themeSettings = settings;
  sliderDomId = `gwj-featured-topic-slider-${Math.random().toString(36).slice(2, 9)}`;

  @tracked isLoading = true;
  @tracked topics = [];
  @tracked error = null;
  @tracked activeIndex = 0;
  @tracked lastSignature = null;
  @tracked parallaxOffsets = new Map();
  @tracked prefersReducedMotion = false;
  @tracked viewportHasOverflow = null;

  #requestInFlight = null;
  #viewportElement = null;
  #motionPreferenceDisposer = null;
  #resizeListenerAttached = false;
  #handleResize = () => this.#scheduleOverflowMeasure();

  get hasTopics() {
    return Array.isArray(this.topics) && this.topics.length > 0;
  }

  get showHeading() {
    return this.themeSettings.show_title && this.themeSettings.title_text?.length;
  }

  get skeletonCount() {
    const desktopSlides = Math.max(Number(this.themeSettings.slides_desktop) || 3, 1);
    const topicQuota = Math.max(Number(this.themeSettings.topic_count) || desktopSlides, 1);
    return Math.min(desktopSlides, topicQuota);
  }

  get skeletonPlaceholders() {
    return Array.from({ length: this.skeletonCount }, (_, index) => index);
  }

  get cacheContext() {
    return this.args?.cacheContext || window.location.pathname || "default";
  }

  get featuredTag() {
    return this.themeSettings.featured_tag?.trim();
  }

  get topicQuota() {
    return Number(this.themeSettings.topic_count) || 0;
  }

  get currentLocale() {
    return I18n?.currentLocale?.() || this.site.locale || "en";
  }

  get fetchSignature() {
    return [
      this.currentLocale,
      this.featuredTag || "none",
      this.topicQuota,
      this.themeSettings.include_pinned ? "pinned" : "no-pinned",
      this.themeSettings.shuffle_topics ? "shuffle" : "ordered",
      this.cacheContext,
    ].join("|");
  }

  get topicCards() {
    if (!this.hasTopics) {
      return [];
    }

    return this.topics.map((topic) => {
      const image = resolveTopicImage(topic, this.site);
      const category = topic.category_id
        ? this.site.categories?.find((cat) => cat.id === topic.category_id)
        : null;
      const fancyTitle = topic.fancy_title;
      let safeTitle;
      if (typeof fancyTitle === "string" && fancyTitle.trim().length > 0) {
        safeTitle = trustHTML(emojiUnescape(fancyTitle));
      } else {
        const rawTitle = topic.title || "";
        safeTitle = trustHTML(emojiUnescape(escapeExpression(rawTitle)));
      }

      return {
        topic,
        id: topic.id,
        title: topic.title || "",
        titleHtml: safeTitle,
        url: getURL(`/t/${topic.slug || topic.id}/${topic.id}`),
        excerpt: topic.excerpt,
        image,
        tags: topic.tags || [],
        category,
        author: topic.op_user || topic.posters?.[0],
        lastPostedAt: topic.bumped_at || topic.last_posted_at,
      };
    });
  }

  get sliderInlineStyle() {
    const desktopCount = Math.max(Number(this.themeSettings.slides_desktop) || 3, 1);
    const availableTopics = Array.isArray(this.topics) ? this.topics.length : 0;
    const visibleDesktopCount =
      availableTopics > 0 ? Math.min(desktopCount, availableTopics) : desktopCount;
    const aspectSetting = this.themeSettings.card_aspect_ratio || "16:9";
    const [width, height] = aspectSetting.split(":").map((value) => Number(value) || 1);
    const aspectPercent = (height / width) * 100;

    return `--gwj-slider-desktop-count: ${visibleDesktopCount}; --gwj-slider-aspect-ratio: ${aspectPercent}%;`;
  }

  get showControls() {
    if (this.topicCards.length <= 1) {
      return false;
    }

    if (this.viewportHasOverflow === null) {
      return false;
    }

    return this.viewportHasOverflow;
  }

  get isPrevDisabled() {
    return this.activeIndex <= 0;
  }

  get isNextDisabled() {
    return this.activeIndex >= Math.max(this.topicCards.length - 1, 0);
  }

  @action
  async loadTopics(force = false) {
    if (!force && this.#requestInFlight) {
      return this.#requestInFlight;
    }

    if (!force && this.lastSignature === this.fetchSignature && this.hasTopics) {
      return;
    }

    const signature = this.fetchSignature;

    if (!force && TOPIC_CACHE.has(signature)) {
      const cached = TOPIC_CACHE.get(signature);
      if (cached && Date.now() - cached.timestamp < CACHE_TTL_MS) {
        this.error = null;
        this.topics = cached.topics.slice();
        this.activeIndex = 0;
        this.lastSignature = signature;
        this.isLoading = false;
        this.#scheduleParallaxUpdate();
        this.#scheduleOverflowMeasure();
        return;
      } else {
        TOPIC_CACHE.delete(signature);
      }
    }

    this.isLoading = true;
    this.error = null;
    const options = {
      tag: this.featuredTag,
      topicCount: this.topicQuota,
      includePinned: this.themeSettings.include_pinned,
      shuffle: this.themeSettings.shuffle_topics,
      cacheContext: this.cacheContext,
      locale: this.currentLocale,
    };

    const request = fetchFeaturedTopics(options)
      .then((topics) => {
        if (signature !== this.fetchSignature) {
          return;
        }

        const normalizedTopics = Array.isArray(topics) ? topics.slice() : [];
        this.topics = normalizedTopics;
        this.activeIndex = 0;
        this.lastSignature = signature;
        this.#scheduleParallaxUpdate();
        this.#scheduleOverflowMeasure();
        TOPIC_CACHE.set(signature, {
          topics: normalizedTopics.slice(),
          timestamp: Date.now(),
        });
        if (TOPIC_CACHE.size > 20) {
          let oldestKey = null;
          let oldestTimestamp = Number.POSITIVE_INFINITY;
          for (const [key, value] of TOPIC_CACHE.entries()) {
            if (value.timestamp < oldestTimestamp) {
              oldestTimestamp = value.timestamp;
              oldestKey = key;
            }
          }
          if (oldestKey && oldestKey !== signature) {
            TOPIC_CACHE.delete(oldestKey);
          }
        }
      })
      .catch((error) => {
        this.error = error;
        // eslint-disable-next-line no-console
        console.warn("[featured-topic-slider] Failed to load featured topics", error);
        this.lastSignature = null;
      })
      .finally(() => {
        this.isLoading = false;
        this.#requestInFlight = null;
      });

    this.#requestInFlight = request;
    return request;
  }

  @action
  registerViewport(element) {
    this.#viewportElement = element;
    element.addEventListener("scroll", this.handleViewportScroll, { passive: true });
    this.#setupMotionWatcher();
    this.#scheduleParallaxUpdate();
    this.#scheduleOverflowMeasure();

    if (typeof window !== "undefined" && !this.#resizeListenerAttached) {
      window.addEventListener("resize", this.#handleResize);
      this.#resizeListenerAttached = true;
    }
  }

  @action
  unregisterViewport(element) {
    element.removeEventListener("scroll", this.handleViewportScroll);
    if (this.#viewportElement === element) {
      this.#viewportElement = null;
      this.viewportHasOverflow = null;
    }

    if (typeof window !== "undefined" && this.#resizeListenerAttached) {
      window.removeEventListener("resize", this.#handleResize);
      this.#resizeListenerAttached = false;
    }
  }

  @action
  handleViewportScroll() {
    const viewport = this.#viewportElement;
    if (!viewport) {
      return;
    }

    const cards = viewport.querySelectorAll("[data-slider-index]");
    if (!cards.length) {
      this.parallaxOffsets = new Map();
      return;
    }

    const viewportRect = viewport.getBoundingClientRect();
    const viewportCenter = viewportRect.left + viewportRect.width / 2;
    const viewportWidth = viewportRect.width || 1;

    let closestIndex = 0;
    let closestDistance = Number.POSITIVE_INFINITY;
    const nextOffsets = new Map();

    cards.forEach((card) => {
      const rect = card.getBoundingClientRect();
      const cardCenter = rect.left + rect.width / 2;
      const distanceFromCenter = cardCenter - viewportCenter;
      const normalized = Math.max(-1, Math.min(1, distanceFromCenter / viewportWidth));
      const index = Number(card.dataset.sliderIndex);
      if (Number.isNaN(index)) {
        return;
      }

      if (!this.prefersReducedMotion) {
        const imageOffset = Number((-normalized * 18).toFixed(2));
        nextOffsets.set(index, {
          image: imageOffset,
        });
      }

      const distance = Math.abs(cardCenter - viewportCenter);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = index;
      }
    });

    this.activeIndex = closestIndex;

    this.parallaxOffsets = this.prefersReducedMotion ? new Map() : nextOffsets;
    this.#updateOverflowState();
  }

  scrollToIndex(targetIndex) {
    const viewport = this.#viewportElement;
    if (!viewport) {
      return;
    }

    const boundedIndex = Math.min(Math.max(targetIndex, 0), this.topicCards.length - 1);
    const targetCard = viewport.querySelector(`[data-slider-index="${boundedIndex}"]`);
    if (targetCard) {
      targetCard.scrollIntoView({
        behavior: "smooth",
        inline: "start",
        block: "nearest",
      });
      this.activeIndex = boundedIndex;
      this.#scheduleParallaxUpdate();
    }
  }

  @action
  focusNext() {
    this.scrollToIndex(this.activeIndex + 1);
  }

  @action
  focusPrev() {
    this.scrollToIndex(this.activeIndex - 1);
  }

  @action
  handleSignatureChange() {
    if (this.fetchSignature === this.lastSignature && this.hasTopics) {
      return;
    }
    this.loadTopics(true);
  }

  @action
  cardParallaxStyle(index) {
    if (this.prefersReducedMotion) {
      return null;
    }

    const offsets = this.parallaxOffsets.get(index);
    if (!offsets) {
      return null;
    }

    return trustHTML(
      `--gwj-parallax-image:${offsets.image}px;`
    );
  }

  #scheduleParallaxUpdate() {
    if (typeof window === "undefined") {
      return;
    }
    window.requestAnimationFrame(() => this.handleViewportScroll());
  }

  #scheduleOverflowMeasure() {
    if (typeof window === "undefined") {
      return;
    }
    window.requestAnimationFrame(() => this.#updateOverflowState());
  }

  #updateOverflowState() {
    const viewport = this.#viewportElement;

    if (!viewport) {
      if (this.viewportHasOverflow !== null) {
        this.viewportHasOverflow = null;
      }
      return;
    }

    const hasOverflow = viewport.scrollWidth - viewport.clientWidth > 1;

    if (this.viewportHasOverflow !== hasOverflow) {
      this.viewportHasOverflow = hasOverflow;
    }
  }

  #setupMotionWatcher() {
    if (this.#motionPreferenceDisposer || typeof window === "undefined") {
      return;
    }

    const mediaQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
    const handleChange = (event) => {
      this.prefersReducedMotion = event.matches;
      if (this.prefersReducedMotion) {
        this.parallaxOffsets = new Map();
      } else {
        this.#scheduleParallaxUpdate();
      }
    };

    if (mediaQuery.addEventListener) {
      mediaQuery.addEventListener("change", handleChange);
      this.#motionPreferenceDisposer = () =>
        mediaQuery.removeEventListener("change", handleChange);
    } else if (mediaQuery.addListener) {
      mediaQuery.addListener(handleChange);
      this.#motionPreferenceDisposer = () => mediaQuery.removeListener(handleChange);
    }

    this.prefersReducedMotion = mediaQuery.matches;
    if (this.prefersReducedMotion) {
      this.parallaxOffsets = new Map();
    }
  }

  willDestroy() {
    if (typeof super.willDestroy === "function") {
      super.willDestroy(...arguments);
    }
    if (typeof window !== "undefined" && this.#resizeListenerAttached) {
      window.removeEventListener("resize", this.#handleResize);
      this.#resizeListenerAttached = false;
    }
    if (this.#motionPreferenceDisposer) {
      this.#motionPreferenceDisposer();
      this.#motionPreferenceDisposer = null;
    }
  }

  <template>
    <div
      class="gwj-featured-topic-slider-wrapper"
      data-featured-topic-slider="true"
      role="region"
      aria-label={{i18n (themePrefix "featured_topic_slider.region_label")}}
      aria-busy={{this.isLoading}}
      {{didInsert this.loadTopics}}
      {{didUpdate this.handleSignatureChange this.fetchSignature}}
      style={{this.sliderInlineStyle}}
    >
      <div class="gwj-featured-topic-slider-wrapper__header">
        {{#if this.showHeading}}
          <h2 class="gwj-featured-topic-slider-wrapper__heading">
            {{this.themeSettings.title_text}}
          </h2>
        {{/if}}

        {{#if this.showControls}}
          <div class="gwj-featured-topic-slider-wrapper__controls">
            <button
              type="button"
              class="gwj-featured-topic-slider-wrapper__control"
              aria-label={{i18n (themePrefix "featured_topic_slider.previous_label")}}
              aria-controls={{this.sliderDomId}}
              {{on "click" this.focusPrev}}
              disabled={{this.isPrevDisabled}}
            >
              {{icon "angle-left"}}
            </button>
            <button
              type="button"
              class="gwj-featured-topic-slider-wrapper__control"
              aria-label={{i18n (themePrefix "featured_topic_slider.next_label")}}
              aria-controls={{this.sliderDomId}}
              {{on "click" this.focusNext}}
              disabled={{this.isNextDisabled}}
            >
              {{icon "angle-right"}}
            </button>
          </div>
        {{/if}}
      </div>

      {{#if this.isLoading}}
        <div
          class="gwj-featured-topic-slider-wrapper__viewport gwj-featured-topic-slider-wrapper__viewport--skeleton"
          aria-hidden="true"
        >
          <div class="gwj-featured-topic-slider-wrapper__track">
            {{#each this.skeletonPlaceholders as |index|}}
              <article
                class="gwj-featured-topic-slider-wrapper__card gwj-featured-topic-slider-wrapper__card--skeleton"
              >
                <div class="gwj-featured-topic-slider-wrapper__media">
                  <div class="gwj-featured-topic-slider-wrapper__skeleton-block"></div>
                </div>
                <div class="gwj-featured-topic-slider-wrapper__body">
                  <div class="gwj-featured-topic-slider-wrapper__skeleton-line gwj-featured-topic-slider-wrapper__skeleton-line--title"></div>
                  <div class="gwj-featured-topic-slider-wrapper__skeleton-line gwj-featured-topic-slider-wrapper__skeleton-line--meta"></div>
                </div>
              </article>
            {{/each}}
          </div>
        </div>
      {{else if this.hasTopics}}
        <div
          id={{this.sliderDomId}}
          class="gwj-featured-topic-slider-wrapper__viewport"
          role="list"
          {{didInsert this.registerViewport}}
          {{willDestroy this.unregisterViewport}}
        >
          <div class="gwj-featured-topic-slider-wrapper__track">
            {{#each this.topicCards as |card index|}}
              <article
                class="gwj-featured-topic-slider-wrapper__card"
                data-slider-index={{index}}
                role="listitem"
                style={{this.cardParallaxStyle index}}
              >
                <a
                  href={{card.url}}
                  class="gwj-featured-topic-slider-wrapper__card-link"
                >
                  <div class="gwj-featured-topic-slider-wrapper__media">
                    {{#if card.image}}
                      <img
                        src={{card.image.url}}
                        alt={{card.image.alt}}
                        loading="lazy"
                      />
                    {{else}}
                      <div class="gwj-featured-topic-slider-wrapper__media--fallback">
                        {{icon "cannabis"}}
                      </div>
                    {{/if}}
                  </div>
                  <div class="gwj-featured-topic-slider-wrapper__body">
                    <h3
                      class="gwj-featured-topic-slider-wrapper__title"
                      aria-label={{card.title}}
                    >
                      {{card.titleHtml}}
                    </h3>

                    {{#unless this.themeSettings.hide_tag_chip}}
                      {{#if card.tags.length}}
                        <span class="gwj-featured-topic-slider-wrapper__tag">
                          {{card.tags.[0]}}
                        </span>
                      {{/if}}
                    {{/unless}}

                    <div class="gwj-featured-topic-slider-wrapper__meta">
                      {{#if card.category}}
                        <span class="gwj-featured-topic-slider-wrapper__category">
                          {{categoryBadge card.category}}
                        </span>
                      {{/if}}
                      {{#if card.lastPostedAt}}
                        <span class="gwj-featured-topic-slider-wrapper__time">
                          {{formatDate card.lastPostedAt format="tiny"}}
                        </span>
                      {{/if}}
                    </div>
                  </div>
                </a>
              </article>
            {{/each}}
          </div>
        </div>
      {{else}}
        <div class="gwj-featured-topic-slider-wrapper__status">
          {{i18n (themePrefix "featured_topic_slider.no_topics")}}
        </div>
      {{/if}}
    </div>
  </template>
}
