import { getURLWithCDN } from "discourse/lib/get-url";

export function resolveTopicImage(topic, site) {
  if (!topic) {
    return null;
  }

  const url =
    topic.image_url ||
    topic.imageUrl ||
    topic.thumbnails?.[0]?.url ||
    (topic.category_id &&
      site?.categories?.find((category) => category.id === topic.category_id)?.uploaded_logo?.url) ||
    site?.siteSettings?.logo_small_url ||
    site?.siteSettings?.logo_url;

  if (!url) {
    return null;
  }

  return {
    url: getURLWithCDN(url),
    alt: topic.fancy_title || topic.title,
  };
}
