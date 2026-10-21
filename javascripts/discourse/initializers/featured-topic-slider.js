/* global settings */

import { withPluginApi } from "discourse/lib/plugin-api";
import {
  ensureRowWrapper,
  queryTopicListElements,
  resolvePlacementSettings,
} from "../lib/gwj-slider-placement";

const ANCHOR_SELECTOR = '[data-featured-topic-slider-anchor="dynamic"]';
const SLIDER_SELECTOR = '[data-featured-topic-slider="true"]';

export default {
  name: "gwj-featured-topic-slider",

  initialize() {
    withPluginApi((api) => {
      const themeSettings = settings || {};
      const state = {
        anchor: null,
        sliderElement: null,
        rowWrapper: null,
        randomTargetIndex: null,
        observer: null,
        observerTarget: null,
      };

      function isAfterNMode() {
        return themeSettings.insert_mode === "after_n";
      }

      function clampIndex(index, upperBound) {
        if (!upperBound || upperBound <= 0) {
          return 0;
        }

        if (index < 1) {
          return 1;
        }

        if (index > upperBound) {
          return upperBound;
        }

        return index;
      }

      function restoreSliderToAnchor() {
        if (!state.anchor) {
          return;
        }

        if (!state.anchor.isConnected) {
          state.anchor = null;
          return;
        }

        if (state.sliderElement?.parentNode !== state.anchor && state.sliderElement) {
          state.anchor.appendChild(state.sliderElement);
        }

        state.anchor.style.display = "";
      }

      function detachRowWrapper() {
        if (state.rowWrapper?.isConnected) {
          state.rowWrapper.remove();
        }
        state.rowWrapper = null;
      }

      function disconnectObserver() {
        if (state.observer) {
          state.observer.disconnect();
          state.observer = null;
          state.observerTarget = null;
        }
      }

      function teardown() {
        state.randomTargetIndex = null;
        detachRowWrapper();
        restoreSliderToAnchor();
        disconnectObserver();

        if (state.sliderElement && !state.sliderElement.isConnected) {
          state.sliderElement = null;
        }

        if (state.anchor && !state.anchor.isConnected) {
          state.anchor = null;
        }
      }

      function ensureElementsReady(callback) {
        state.anchor = document.querySelector(ANCHOR_SELECTOR);
        if (!state.anchor) {
          teardown();
          return;
        }

        if (!state.anchor.isConnected) {
          state.anchor = null;
          teardown();
          return;
        }

        if (!state.sliderElement || !state.sliderElement.isConnected) {
          state.sliderElement =
            state.anchor.querySelector(SLIDER_SELECTOR) ||
            document.querySelector(SLIDER_SELECTOR);
        }

        if (!state.sliderElement) {
          window.requestAnimationFrame(() => ensureElementsReady(callback));
          return;
        }

        callback?.();
      }

      function ensureObserver() {
        const listArea = document.querySelector("#list-area");
        if (!listArea) {
          disconnectObserver();
          return;
        }

        if (state.observer && state.observerTarget === listArea) {
          return;
        }

        disconnectObserver();

        state.observer = new MutationObserver(() => {
          schedulePlacement();
        });

        state.observer.observe(listArea, {
          childList: true,
          subtree: true,
        });

        state.observerTarget = listArea;
      }

      function runPlacement() {
        if (!isAfterNMode() || !state.anchor || !state.sliderElement) {
          return;
        }

        const topicListElements = queryTopicListElements();
        if (!topicListElements?.topicList) {
          restoreSliderToAnchor();
          return;
        }

        const { bodyRows, columnCount } = topicListElements;
        const listLength = bodyRows.length;

        if (!listLength) {
          restoreSliderToAnchor();
          return;
        }

        const placementConfig = resolvePlacementSettings(themeSettings);
        const minIndex = clampIndex(placementConfig.minIndex, listLength);
        const maxIndex = clampIndex(placementConfig.maxIndex, listLength);

        let targetIndex;
        if (placementConfig.randomize) {
          if (!state.randomTargetIndex) {
            const range = Math.max(maxIndex - minIndex + 1, 1);
            const offset = Math.floor(Math.random() * range);
            state.randomTargetIndex = minIndex + offset;
          }
          targetIndex = clampIndex(state.randomTargetIndex, listLength);
        } else {
          state.randomTargetIndex = null;
          targetIndex = clampIndex(placementConfig.positionIndex, listLength);
        }

        const rowWrapper = ensureRowWrapper({
          sliderElement: state.sliderElement,
          columnCount,
        });
        state.rowWrapper = rowWrapper;

        const tbody = bodyRows[0]?.parentNode;
        if (!tbody) {
          restoreSliderToAnchor();
          return;
        }

        const referenceRow = bodyRows[Math.min(targetIndex, listLength) - 1];
        tbody.insertBefore(rowWrapper, referenceRow?.nextSibling || null);

        if (state.anchor && state.sliderElement.parentNode !== state.anchor) {
          state.anchor.style.display = "none";
        }
      }

      function schedulePlacement() {
        window.requestAnimationFrame(runPlacement);
      }

      function handleRouteChange() {
        if (!isAfterNMode()) {
          teardown();
          return;
        }

        window.requestAnimationFrame(() => {
          ensureElementsReady(() => {
            ensureObserver();
            state.randomTargetIndex = null;
            schedulePlacement();
          });
        });
      }

      api.onPageChange(() => {
        handleRouteChange();
      });

      handleRouteChange();
    });
  },
};
