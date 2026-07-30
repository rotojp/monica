<?php

namespace App\Http\Resources;

use App\Helpers\DateHelper;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\ContactImportantDate
 */
class ContactImportantDateResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     */
    public function toArray($request): array
    {
        return [
            'id' => $this->id,
            'label' => $this->label,
            'day' => $this->day,
            'month' => $this->month,
            'year' => $this->year,
            'contact_important_date_type' => $this->contactImportantDateType ? [
                'id' => $this->contactImportantDateType->id,
                'label' => $this->contactImportantDateType->label,
                'internal_type' => $this->contactImportantDateType->internal_type,
            ] : null,
            'created_at' => DateHelper::getTimestamp($this->created_at),
            'updated_at' => DateHelper::getTimestamp($this->updated_at),
        ];
    }
}
