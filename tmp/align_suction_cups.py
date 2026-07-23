from collections import deque
from math import pi, sqrt
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
remove_cups = "--remove-cups" in sys.argv[3:]
source = Image.open(source_path).convert("RGB")
pixels = np.asarray(source)
height, width = pixels.shape[:2]

# Segment the flat visual roles in the generated source. The loose thresholds
# retain its antialiased silhouette while separating the white cups reliably.
navy = (
    (pixels[:, :, 0] < 55)
    & (pixels[:, :, 1] < 125)
    & (pixels[:, :, 2] < 165)
)
white = (
    (pixels[:, :, 0] > 225)
    & (pixels[:, :, 1] > 225)
    & (pixels[:, :, 2] > 225)
)


def connected_components(mask: np.ndarray):
    seen = np.zeros(mask.shape, dtype=bool)
    components = []
    for y, x in zip(*np.nonzero(mask)):
        if seen[y, x]:
            continue
        queue = deque([(int(y), int(x))])
        seen[y, x] = True
        points = []
        while queue:
            py, px = queue.popleft()
            points.append((py, px))
            for ny, nx in ((py - 1, px), (py + 1, px), (py, px - 1), (py, px + 1)):
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        components.append(points)
    return components


# The outside corners are one large white component. Cup components are small,
# compact circles inside the tile.
cup_components = []
for component in connected_components(white):
    area = len(component)
    if not 250 <= area <= 2500:
        continue
    ys = np.fromiter((point[0] for point in component), dtype=float)
    xs = np.fromiter((point[1] for point in component), dtype=float)
    cx = float(xs.mean())
    cy = float(ys.mean())
    if 45 < cx < width - 45 and 45 < cy < height - 45:
        cup_components.append((component, cx, cy, sqrt(area / pi)))

# Image generation can overproduce repeated details. Partition the detected
# cups into the eight radial arms and sample exactly nine positions along each
# existing curve before performing the boundary alignment.
center_x = width / 2.0
center_y = height / 2.0
groups = [[] for _ in range(8)]
for cup in cup_components:
    _, cx, cy, _ = cup
    angle = np.arctan2(cy - center_y, cx - center_x)
    group_index = int(np.round(angle / (pi / 4.0))) % 8
    groups[group_index].append(cup)


def ordered_curve(cups):
    coordinates = np.array([(cup[1], cup[2]) for cup in cups])
    pairwise = coordinates[:, None, :] - coordinates[None, :, :]
    distance_sq = np.sum(pairwise * pairwise, axis=2)
    start = int(np.unravel_index(np.argmax(distance_sq), distance_sq.shape)[0])
    order = [start]
    remaining = set(range(len(cups))) - {start}
    while remaining:
        last = order[-1]
        next_index = min(remaining, key=lambda index: distance_sq[last, index])
        order.append(next_index)
        remaining.remove(next_index)
    return [cups[index] for index in order]


all_cup_components = list(cup_components)
selected_cups = []
selected_groups = []
for group in groups:
    if len(group) < 9:
        raise RuntimeError(f"Expected at least 9 cups per arm, found {len(group)}")
    ordered = ordered_curve(group)
    sample_indices = np.round(np.linspace(0, len(ordered) - 1, 9)).astype(int)
    selected_group = [ordered[index] for index in sample_indices]
    selected_groups.append(selected_group)
    selected_cups.extend(selected_group)

cup_components = selected_cups

cup_mask = np.zeros((height, width), dtype=bool)
for component, _, _, _ in all_cup_components:
    for y, x in component:
        cup_mask[y, x] = True

# Cover the antialiased fringe around every original generated cup so omitted
# overproduced cups disappear cleanly into the reconstructed navy silhouette.
for _ in range(4):
    expanded = cup_mask.copy()
    expanded[1:, :] |= cup_mask[:-1, :]
    expanded[:-1, :] |= cup_mask[1:, :]
    expanded[:, 1:] |= cup_mask[:, :-1]
    expanded[:, :-1] |= cup_mask[:, 1:]
    cup_mask = expanded

# Treat the cups as part of the tentacle when measuring its true silhouette.
arm = navy | cup_mask

# Collect only background pixels immediately adjacent to the navy silhouette.
neighboring_arm = np.zeros_like(arm)
neighboring_arm[1:, :] |= arm[:-1, :]
neighboring_arm[:-1, :] |= arm[1:, :]
neighboring_arm[:, 1:] |= arm[:, :-1]
neighboring_arm[:, :-1] |= arm[:, 1:]
boundary_yx = np.column_stack(np.nonzero((~arm) & neighboring_arm))

neighboring_background = np.zeros_like(arm)
neighboring_background[1:, :] |= ~arm[:-1, :]
neighboring_background[:-1, :] |= ~arm[1:, :]
neighboring_background[:, 1:] |= ~arm[:, :-1]
neighboring_background[:, :-1] |= ~arm[:, 1:]
inside_boundary = arm & neighboring_background

new_cups = []
for raw_group in groups:
    group = ordered_curve(raw_group)
    group_x = np.array([cup[1] for cup in group])
    group_y = np.array([cup[2] for cup in group])
    # The mean of a C-shaped cup row lies inside its curl. Nudge that estimate
    # slightly toward the icon center to land in the aquamarine hook cavity.
    cavity_x = float(group_x.mean() + (center_x - group_x.mean()) * 0.10)
    cavity_y = float(group_y.mean() + (center_y - group_y.mean()) * 0.10)

    # Ensure the estimate is actually inside the aquamarine cavity.
    estimate_x = int(round(cavity_x))
    estimate_y = int(round(cavity_y))
    if arm[estimate_y, estimate_x]:
        search_radius = 100
        y0 = max(0, estimate_y - search_radius)
        y1 = min(height, estimate_y + search_radius + 1)
        x0 = max(0, estimate_x - search_radius)
        x1 = min(width, estimate_x + search_radius + 1)
        candidates = np.column_stack(np.nonzero(~arm[y0:y1, x0:x1]))
        candidate_y = candidates[:, 0] + y0
        candidate_x = candidates[:, 1] + x0
        candidate_distance = (candidate_x - cavity_x) ** 2 + (candidate_y - cavity_y) ** 2
        nearest = int(np.argmin(candidate_distance))
        cavity_x = float(candidate_x[nearest])
        cavity_y = float(candidate_y[nearest])

    radius = min(float(np.median([cup[3] for cup in group])), 13.5)

    def project_to_outer_edge(cup):
        _, cx, cy, _ = cup
        # Travel away from the hook cavity to reach the opposite, convex edge.
        vector_x = cx - cavity_x
        vector_y = cy - cavity_y
        length = sqrt(vector_x * vector_x + vector_y * vector_y)
        unit_x = vector_x / length
        unit_y = vector_y / length
        previous = (int(round(cy)), int(round(cx)))
        for step in np.arange(0.5, 260.0, 0.5):
            sample_x = int(round(cx + unit_x * step))
            sample_y = int(round(cy + unit_y * step))
            if not (0 <= sample_x < width and 0 <= sample_y < height):
                break
            if not arm[sample_y, sample_x]:
                return previous
            previous = (sample_y, sample_x)
        raise RuntimeError("Could not project cup to outer edge")

    start = project_to_outer_edge(group[0])
    goal = project_to_outer_edge(group[-1])

    # Snap projections onto the one-pixel inside-boundary contour.
    local_boundary = np.column_stack(np.nonzero(inside_boundary))
    for point_name, point in (("start", start), ("goal", goal)):
        if not inside_boundary[point[0], point[1]]:
            delta = local_boundary - np.array(point)
            nearest = int(np.argmin(np.sum(delta * delta, axis=1)))
            if point_name == "start":
                start = tuple(int(value) for value in local_boundary[nearest])
            else:
                goal = tuple(int(value) for value in local_boundary[nearest])

    # Follow the local contour between the two projected outer-edge endpoints.
    maximum_radius = 260.0
    def trace_boundary(path_start, path_goal):
        queue = deque([path_start])
        parent = {path_start: None}
        while queue and path_goal not in parent:
            point_y, point_x = queue.popleft()
            for next_y in range(point_y - 1, point_y + 2):
                for next_x in range(point_x - 1, point_x + 2):
                    next_point = (next_y, next_x)
                    if next_point == (point_y, point_x) or next_point in parent:
                        continue
                    if not (0 <= next_x < width and 0 <= next_y < height):
                        continue
                    if not inside_boundary[next_y, next_x]:
                        continue
                    if (next_x - cavity_x) ** 2 + (next_y - cavity_y) ** 2 > maximum_radius ** 2:
                        continue
                    parent[next_point] = (point_y, point_x)
                    queue.append(next_point)
        if path_goal not in parent:
            raise RuntimeError("Could not trace concave inner boundary")
        traced = []
        point = path_goal
        while point is not None:
            traced.append(point)
            point = parent[point]
        traced.reverse()
        return traced

    path = trace_boundary(start, goal)

    path_xy = np.array([(point[1], point[0]) for point in path], dtype=float)
    segments = path_xy[1:] - path_xy[:-1]
    segment_lengths = np.sqrt(np.sum(segments * segments, axis=1))
    cumulative = np.concatenate(([0.0], np.cumsum(segment_lengths)))
    total_length = float(cumulative[-1])

    for target in np.linspace(0.0, total_length, 9):
        segment_index = min(int(np.searchsorted(cumulative, target, side="right") - 1), len(segments) - 1)
        segment_length = segment_lengths[segment_index]
        fraction = 0.0 if segment_length == 0 else (target - cumulative[segment_index]) / segment_length
        edge_point = path_xy[segment_index] + segments[segment_index] * fraction
        normal_x = edge_point[0] - cavity_x
        normal_y = edge_point[1] - cavity_y
        normal_length = sqrt(normal_x * normal_x + normal_y * normal_y)
        normal_x /= normal_length
        normal_y /= normal_length
        new_cups.append((
            float(edge_point[0] - normal_x * (radius + 5.0)),
            float(edge_point[1] - normal_y * (radius + 5.0)),
            radius,
        ))

# Flatten the palette and reconstruct the old cup holes as navy.
scale = 4
canvas = Image.new("RGBA", (width * scale, height * scale), (0, 0, 0, 0))
tile = Image.new("L", canvas.size, 0)
tile_draw = ImageDraw.Draw(tile)
corner_radius = int(width * 0.175 * scale)
tile_draw.rounded_rectangle(
    (0, 0, width * scale - 1, height * scale - 1),
    radius=corner_radius,
    fill=255,
)
background = Image.new("RGBA", canvas.size, (64, 183, 184, 255))
canvas.paste(background, (0, 0), tile)

arm_image = Image.fromarray((arm.astype(np.uint8) * 255), mode="L")
arm_image = arm_image.resize(canvas.size, Image.Resampling.LANCZOS)
navy_layer = Image.new("RGBA", canvas.size, (0, 58, 84, 255))
canvas.paste(navy_layer, (0, 0), arm_image)

draw = ImageDraw.Draw(canvas)
if not remove_cups:
    for cx, cy, radius in new_cups:
        x = cx * scale
        y = cy * scale
        r = radius * scale
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))

canvas = canvas.resize((width, height), Image.Resampling.LANCZOS)
canvas.save(output_path)
print(f"Aligned {len(new_cups)} cups; saved {output_path}")
