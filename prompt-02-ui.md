***

# Prompt for Frontend Application Architecture & UI Implementation

## Role & Objective
You are an expert Frontend Architect and Senior UI/UX Engineer. Your task is to build a full frontend application architecture and implement a multi-agent dashboard UI from scratch. The UI must strictly follow the **UBS corporate theme and design system** (stark white background `#FFFFFF`, deep charcoal typography `#111111`, and signature UBS red `#E60000` for primary actions and highlights).

For now, build the UI using **robust mock data** (structured TypeScript types/interfaces) with a clean service layer abstraction so it can easily be swapped out with real REST APIs later. Additionally, you must integrate organization-specific components from `@org/xyz-design-system` where applicable.

---

## 1. Technical Stack & Architecture Guidelines
- **Framework:** React 19.
- **Design System:** Use components from `@org/xyz-design-system` (e.g., `<Button>`, `<Card>`, `<Modal>`, `<Badge>`, `<Tooltip>`, `<Dropdown>`) for standard UI elements.
- **State Management:** Zustand or React Context for managing favorite agents, active filters, and the floating Help Bot open/closed state.
- **Icons:** `@org/xyz-design-system` icons.

---

## 2. Component Architecture & Directory Structure
Structure the project cleanly using feature-based or atomic design principles:

```text
src/
├── app/                 
│   ├── layout.tsx
│   └── page.tsx          # Dashboard Home
├── components/
│   ├── common/           # Wrappers around @org/xyz-design-system
│   ├── layout/           # Sidebar, Header, Footer
│   ├── dashboard/        # Dashboard-specific components
│   │   ├── FavoriteAgents.tsx
│   │   ├── AgentGrid.tsx
│   │   ├── AgentCard.tsx
│   │   └── HelpBotWidget.tsx  # Bottom-right floating button & chat popover
│   └── ui/
├── mock/
│   └── agents.ts         # Mock data for agents, categories, and chat responses
├── types/
│   └── agent.ts          # TypeScript interfaces
└── services/
    └── agentService.ts   # API abstraction layer (currently returning mock data)
```

---

## 3. Detailed UI & Functional Specifications

### A. Global Theme (UBS Design Standard)
- **Background:** Crisp white (`#FFFFFF`) / light grey card surfaces (`#F9F9F9`).
- **Text:** Deep charcoal (`#111111`) for headings, dark slate (`#555555`) for secondary text.
- **Accents:** Signature UBS Red (`#E60000`) for active states, badges, primary CTA buttons, and the Help Bot icon.
- **Borders & Shadows:** Subtle, clean 1px borders (`#E5E5E5`) with minimal, crisp elevation shadows.

### B. Layout & Navigation
- **Left Sidebar:**
  - Organization logo/branding at the top.
  - Navigation links: *Dashboard, All Agents, Analytics, Settings*.
  - Clean, minimalist styling matching financial enterprise portals.
- **Main Content Area:**
  - **No** market snapshots, insights, or recent activity feeds.
  - Clean page title: *"Agent Command Center"*.

### C. Favorite Agents Section (Top of Content)
- Prominent section displaying pinned/favorite specialized agents in a clean responsive grid.
- Each card shows:
  - Agent avatar / icon
  - Name and role (e.g., *Compliance Bot*, *Risk Analytics Assistant*, *Market Research Agent*)
  - Status indicator (Active / Idle)
  - Quick-launch / "Chat Now" button using `@org/xyz-design-system` components.
  - Star / unstar toggle to manage favorites.

### D. All Agents Directory
- Grid displaying the complete list of available AI agents.
- Search bar and category filters (e.g., *Finance, Operations, Legal, Risk*).

### E. Floating Help Bot Support Widget (Bottom-Right Corner)
- **Positioning:** Fixed at `bottom-6 right-6` with a high `z-index`.
- **Trigger Button:** A circular button styled in signature UBS Red (`#E60000`) with a support/chat icon from `@org/xyz-design-system`.
- **Floating Component (Popover/Drawer):**
  - Appears when the Help Bot icon is clicked.
  - Header: "Support Assistant" with a close (`X`) button.
  - Body: A clean chat message history interface with mock FAQs and support prompts.
  - Input Footer: Text input and send button to interact with the support bot.
  - State managed locally or via Zustand (`isHelpBotOpen: boolean`).

---

## 4. Mock Data & Service Layer (`src/mock/agents.ts`)
Create structured mock data for agents with properties:
```ts
export interface Agent {
  id: string;
  name: string;
  category: string;
  description: string;
  isFavorite: boolean;
  status: 'active' | 'idle' | 'maintenance';
  version: string;
}
```
Implement `agentService.ts` to fetch these mock datasets asynchronously (`async getAgents()`, `async toggleFavorite(id)`, etc.) simulating API latency so it's ready for real endpoint integration.

---

## 5. Acceptance Criteria
1. **Design System Integration:** All buttons, cards, and core elements successfully import and utilize `@org/xyz-design-system` components (e.g., `import { Button, Card } from '@org/xyz-design-system'`).
2. **Theme Accuracy:** The UI strictly adheres to the UBS color palette (White, Charcoal, `#E60000` Red accents).
3. **Clean Layout:** Market snapshots, insights, and activity feeds are absent. Only Favorite Agents, the Agent Directory, and the Sidebar are rendered in the main view.
4. **Interactive Help Bot:** The bottom-right floating button toggles the chat popover smoothly without layout shifts.
5. **Type Safety:** Written entirely in TypeScript with strict typing and zero build errors.